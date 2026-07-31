# Plan: registrations are permanently lost when a node leaves the cluster

## 1. The issue

When a node is removed from a `Horde.Registry`'s membership, **all names it
registered are deleted permanently**, even if the registered processes are
still alive. If the node later rejoins the cluster, the names do not come back:
nothing re-registers them, because the processes never died.

This makes a transient membership change (a `nodedown` blip, a peer seeing an
incomplete `Node.list`) cause a permanent outage of whatever is registered under
those names — in Astarte's case, the shared `RPC.Server` stays alive and
supervised but becomes unreachable via its via-name forever.

## 2. Reproduce manually

From this repo (`mix run script.exs`, or copy-paste into `iex -S mix`):

```elixir
{:ok, _} = Horde.Registry.start_link(name: :reg_a, keys: :unique, members: [:reg_a])
{:ok, _} = Horde.Registry.start_link(name: :reg_b, keys: :unique, members: [:reg_b])

Horde.Cluster.set_members(:reg_a, [:reg_a, :reg_b])
Horde.Cluster.set_members(:reg_b, [:reg_a, :reg_b])
Process.sleep(200)

{:ok, pid} = Horde.Registry.register(:reg_a, "key", :value)
Process.sleep(200)
Horde.Registry.lookup(:reg_b, "key")   # => [{pid, :value}]   (registered, visible)

# reg_a "goes down": reg_b evicts it from membership
Horde.Cluster.set_members(:reg_b, [:reg_b])
Process.sleep(200)
Horde.Registry.lookup(:reg_b, "key")   # => []                (hidden: reg_a out of membership)
Process.alive?(pid)                    # => true              (process never died)

# reg_a rejoins
Horde.Cluster.set_members(:reg_a, [:reg_a, :reg_b])
Horde.Cluster.set_members(:reg_b, [:reg_a, :reg_b])
Process.sleep(300)

Horde.Registry.lookup(:reg_b, "key")   # => []   <-- BUG: should be [{pid, :value}]
Horde.Registry.lookup(:reg_a, "key")   # => []   <-- BUG: even its own node lost it
Process.alive?(pid)                    # => true              (process is still alive)
```

Observed on current code: after the rejoin the key is gone on **both** nodes
while the process is still alive. Verified above.

## 3. ExUnit test that reproduces it

The current suite enshrines the buggy behavior in
`test/registry_test.exs:802-838` ("a node is removed from the cluster and its
processes are cleaned up"): it asserts that a removed member's entries are gone.
The test below asserts the opposite, and fails on current code:

```elixir
test "a key registered by a removed member is restored when the member rejoins" do
  reg1 = start_registry()
  reg2 = start_registry()
  pid = self()

  Horde.Cluster.set_members(reg1, [reg1, reg2])
  Horde.Cluster.set_members(reg2, [reg1, reg2])
  Process.sleep(100)

  {:ok, _} = Horde.Registry.register(reg1, "key", :value)
  Process.sleep(100)
  assert [{^pid, :value}] = Horde.Registry.lookup(reg2, "key")
  assert [{^pid, :value}] = Horde.Registry.lookup(reg1, "key")

  # reg1 is evicted by its peer
  Horde.Cluster.set_members(reg2, [reg2])
  Process.sleep(100)
  assert [] = Horde.Registry.lookup(reg2, "key")

  # reg1 rejoins; the name should resolve again without any re-registration
  Horde.Cluster.set_members(reg1, [reg1, reg2])
  Horde.Cluster.set_members(reg2, [reg1, reg2])
  Process.sleep(200)

  assert [{^pid, :value}] = Horde.Registry.lookup(reg2, "key")
end
```

Note: `Horde.Registry.register/3` registers the **calling** process under the
key but replies `{:ok, self()}` of the `RegistryImpl` (`registry_impl.ex:327`),
so the test registers the test process itself and pins `pid = self()` instead
of the returned pid.

The existing test at `test/registry_test.exs:802-838` ("a node is removed from
the cluster and its processes are cleaned up") is updated as part of the fix:
a removed member's registration is now hidden while its process is alive and
cleaned up only once the process exits.

A second test should pin the takeover path (a new replica registering while the
member is gone wins, and a surviving old process gets `{:name_conflict, ...}`).

## 4. Assumptions (why the fix is safe)

### 4.1 Membership and registration are already separate things

The CRDT stores members as `{:member, {name, node}}` and registrations as
`{:key, key} => {member, pid, value}`. "Node X is not a member right now" is a
liveness observation, not proof that X's processes are dead.

### 4.2 Lookups already defend against staleness

`Horde.Registry.lookup/2` (`lib/horde/registry.ex:253-263`) only returns an
entry if **both** of these hold:

- `member_in_cluster?(registry, member)` — the owning member is currently in
  the cluster, and
- `transport.process_alive?(pid)` — the registered process is alive.

So keeping an entry whose owner has left the cluster is harmless: it is simply
invisible until the owner returns (or is overwritten). The eager deletion in
`registry_impl.ex:196-215` (`process_diff({:remove, {:member, member}})` issues
`DeltaCrdt.drop` for every key owned by the member) is therefore not needed for
correctness — it only makes a transient removal permanent.

### 4.3 Add-wins makes re-registration an overwrite, not a conflict

The registry is a `DeltaCrdt.AWLWWMap` (add-wins). Registering a name issues a
fresh `add` with a new dot and a newer timestamp, which beats any previous
entry on merge. Consequences:

- A **new replica** that registers the same name while the old member is gone
  simply wins — no stale entry blocks it (`registry_impl.ex:317-328` replies
  `{:ok, self()}`, `registry.ex` maps that to `:yes`).
- If the **old process is still alive** when that happens, the node processing
  the new add sees an existing entry for the key and sends it
  `{:name_conflict, ...}` (`registry_impl.ex:228-236`); a well-behaved
  registrant (like Astarte's `RPC.Server`) shuts down gracefully. Exactly one
  owner remains in every interleaving.

### 4.4 Without the deletion, the survivor's name is restored on rejoin

The incident scenario: a membership blip removes the node, its `RPC.Server`
never dies, and nothing ever re-registers it. With the deletion removed, the
entry survives, and once the member is re-added the `member_in_cluster?` check
passes again — the name resolves with **zero re-registration**. That is the fix.

### 4.5 Cleanup still happens

- Local process death is already handled by the link between `RegistryImpl`
  and the process (`registry_impl.ex:127-148`): the EXIT drops the keys.
- A new registration overwrites the old entry (4.3).
- Remote/confirmed-dead entries of departed members need a reaping pass
  (GC), which is a follow-up: reap only when the owner is out of the cluster
  **and** its node is reachable **and** the pid is confirmed dead — never on a
  mere `noconnection`, or a partitioned-but-alive process loses its name again.

## 5. Out of scope

- `Horde.DynamicSupervisor` failover is untouched; it already restarts the
  RPC server on a remaining node when the original node is declared dead.
- The crash-cascade fix (registry restart taking down the supervision tree) is
  PR #290, already merged.
