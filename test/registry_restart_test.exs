defmodule RegistryRestartTest do
  use ExUnit.Case, async: false

  setup do
    nodes = LocalCluster.start_nodes("restart-#{System.unique_integer([:positive])}", 3)

    for n <- nodes do
      :erpc.call(n, Application, :ensure_all_started, [:test_app])
      # each supervisor stays isolated (sole member) so starts land locally
      :ok = :erpc.call(n, Horde.Cluster, :set_members, [TestSup, [{TestSup, n}]])
    end

    [owner: Enum.at(nodes, 0), survivor: Enum.at(nodes, 1), fresh: Enum.at(nodes, 2)]
  end

  test "a stale entry left by a dead node must not kill a fresh registration", %{
    owner: owner,
    survivor: survivor,
    fresh: fresh
  } do
    join_reg([owner, survivor])

    # the owner registers a name; the survivor replicates it
    {:ok, pid_old} = :erpc.call(owner, Worker, :start, [:key])
    assert node(pid_old) == owner
    assert [{^pid_old, nil}] = await_lookup(survivor, [{pid_old, nil}])

    # the owner is gone for good: the name is hidden on the survivor,
    # but the raw entry is retained
    LocalCluster.stop_nodes([owner])
    assert [] = await_lookup(survivor, [])
    assert [^pid_old] = select_pids(survivor)

    # in the meantime a fresh node registers the same name on its own
    {:ok, pid_new} = :erpc.call(fresh, Worker, :start, [:key])
    assert node(pid_new) == fresh
    assert [{^pid_new, nil}] = await_lookup(fresh, [{pid_new, nil}])

    # when the fresh node joins, the stale entry arrives: give it time to
    # kill and (without the fix) restart before asserting, so a regression
    # fails on the holder identity instead of racing past
    join_reg([survivor, fresh])
    Process.sleep(1000)

    assert :erpc.call(fresh, Process, :alive?, [pid_new])
    assert [{^pid_new, nil}] = await_lookup(fresh, [{pid_new, nil}])
  end

  defp await_lookup(node, expected, attempts \\ 40)
  defp await_lookup(_node, _expected, 0), do: :timeout

  defp await_lookup(node, expected, attempts) do
    case :erpc.call(node, Horde.Registry, :lookup, [TestReg, :key]) do
      ^expected ->
        expected

      _ ->
        Process.sleep(250)
        await_lookup(node, expected, attempts - 1)
    end
  end

  defp select_pids(node) do
    :erpc.call(node, Horde.Registry, :select, [TestReg, [{{:key, :"$1", :_}, [], [:"$1"]}]])
  end

  defp join_reg(nodes) do
    reg_members = for n <- nodes, do: {TestReg, n}

    for n <- nodes do
      :ok = :erpc.call(n, Horde.Cluster, :set_members, [TestReg, reg_members])
    end
  end
end
