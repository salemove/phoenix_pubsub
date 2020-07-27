defmodule Phoenix.Tracker.StateTest do
  use ExUnit.Case, async: true
  alias Phoenix.Tracker.{State}

  def sorted_clouds(clouds) do
    clouds
    |> Enum.flat_map(fn {_name, cloud} -> Enum.to_list(cloud) end)
    |> Enum.sort()
  end

  defp new(node, config) do
    State.new({node, 1}, :"#{node} #{config.test}")
  end

  defp new_pid() do
    spawn(fn -> :ok end)
  end

  defp keys(elements) do
    elements
    |> Enum.map(fn {{_, _, key},  _, _} -> key end)
    |> Enum.sort()
  end

  defp tab2list(tab), do: tab |> :ets.tab2list() |> Enum.sort()

  test "that this is set up correctly", config do
    a = new(:a, config)
    assert {_a, map} = State.extract(a, a.replica, a.context)
    assert map == %{}
  end

  test "user added online is online", config do
    a = new(:a, config)
    john = new_pid()
    a = State.join(a, john, "lobby", :john)
    assert [{:john, _meta}] = State.get_by_topic(a, "lobby")
    a = State.leave(a, john, "lobby", :john)
    assert [] = State.get_by_topic(a, "lobby")
  end

  test "users from other servers merge", config do
    a = new(:a, config)
    b = new(:b, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()
    carol = new_pid()


    assert [] = tab2list(a.pids)
    a = State.join(a, alice, "lobby", :alice)
    assert [{_, "lobby", :alice}] = tab2list(a.pids)
    b = State.join(b, bob, "lobby", :bob)

    # Merging emits a bob join event
    assert {a, [{{_, _, :bob}, _, _}], []} = State.merge(a, State.extract(b, a.replica, a.context))
    assert [:alice, :bob] = keys(State.online_list(a))

    # Merging twice doesn't dupe events
    pids_before = tab2list(a.pids)
    assert {newa, [], []} = State.merge(a, State.extract(b, a.replica, a.context))
    assert newa == a
    assert pids_before == tab2list(newa.pids)

    assert {b, [{{_, _, :alice}, _, _}], []} = State.merge(b, State.extract(a, b.replica, b.context))
    assert {^b, [], []} = State.merge(b, State.extract(a, b.replica, b.context))

    # observe remove
    assert [{_, "lobby", :alice}, {_, "lobby", :bob}] = tab2list(a.pids)
    a = State.leave(a, alice, "lobby", :alice)
    assert [{_, "lobby", :bob}] = tab2list(a.pids)
    b_pids_before = tab2list(b.pids)
    assert [{_, "lobby", :alice}, {_, "lobby", :bob}] = b_pids_before
    assert {b, [], [{{_, _, :alice}, _, _}]} = State.merge(b, State.extract(a, b.replica, b.context))
    assert [{_, "lobby", :alice}] = b_pids_before -- tab2list(b.pids)

    assert [:bob] = keys(State.online_list(b))
    assert {^b, [], []} = State.merge(b, State.extract(a, b.replica, b.context))

    b = State.join(b, carol, "lobby", :carol)

    assert [:bob, :carol] = keys(State.online_list(b))
    assert {a, [{{_, _, :carol}, _, _}],[]} = State.merge(a, State.extract(b, a.replica, a.context))
    assert {^a, [], []} = State.merge(a, State.extract(b, a.replica, a.context))

    assert (State.online_list(b) |> Enum.sort) == (State.online_list(a) |> Enum.sort)
  end

  test "basic netsplit", config do
    a = new(:a, config)
    b = new(:b, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()
    carol = new_pid()
    david = new_pid()

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    {a, [{{_, _, :bob}, _, _}], _} = State.merge(a, State.extract(b, a.replica, a.context))

    assert [:alice, :bob] = a |> State.online_list() |> keys()

    a = State.join(a, carol, "lobby", :carol)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, david, "lobby", :david)

    assert {a, [] ,[{{_, _, :bob}, _, _}]} = State.replica_down(a, {:b,1})

    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[],[]} = State.merge(a, State.extract(b, a.replica, a.context))
    assert [:carol, :david] = keys(State.online_list(a))

    assert {a,[{{_, _, :bob}, _, _}],[]} = State.replica_up(a, {:b,1})

    assert [:bob, :carol, :david] = keys(State.online_list(a))
  end

  test "todo", config do
    a = new(:a, config)
    b = new(:b, config)
    c = new(:c, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {a, _, _} = State.replica_up(a, c.replica)
    {b, _, _} = State.replica_up(b, a.replica)
    {b, _, _} = State.replica_up(b, c.replica)
    {c, _, _} = State.replica_up(c, a.replica)
    {c, _, _} = State.replica_up(c, b.replica)

    alice = new_pid()
    bob = new_pid()
    carol = new_pid()

    a = State.join(a, alice, "lobby", :alice, %{meta: "foo"})
    b = State.join(b, bob, "lobby", :bob)

    # Node A sends updates to node B
    assert {b, [{{_, _, :alice}, _, _}], _} = State.merge(b, State.extract(a, b.replica, b.context))
    assert [:alice, :bob] = b |> State.online_list() |> keys()

    # Node A does not see node B. Node A is marked as a down replica and its
    # users are in the "leaves" payload.
    assert {b, [] ,[{{_, _, :alice}, _, _}]} = State.replica_down(b, {:a,1})
    assert [:bob] = keys(State.online_list(b))

    # Alice is updated on A (meta changed)
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, alice, "lobby", :alice, %{meta: "bar"})
    a = State.leave(a, alice, "lobby", :alice)
    a = State.join(a, alice, "lobby", :alice, %{meta: "baz"})

    old_b = b

    # carol
    c = State.join(c, carol, "lobby", :carol, %{meta: "foo"})
    assert {a, [{{_, _, :carol}, _, _}], _} = State.merge(a, State.extract(c, a.replica, a.context))
    assert [:alice, :carol] = keys(State.online_list(a))

    # Node A comes back, the old alice is put back to the online list
    assert {b, [{{_, _, :alice}, _, _}],[]} = State.replica_up(b, {:a,1})

    # Node B requests full state from node A
    #
    # IO.inspect(">>>>>>>")
    # IO.inspect(State.merge(b, State.extract(a, b.replica, b.context)))
    # IO.inspect("<<<<<<<<")
    assert {b,
      [
        {{_, _, :carol}, %{meta: "foo"}, _},
        {{_, _, :alice}, %{meta: "baz"}, _}
      ],
      [{{_, _, :alice}, %{meta: "foo"}, _}]
    } = State.merge(b, State.extract(a, b.replica, b.context))


    IO.inspect(State.extract(c, old_b.replica, old_b.context))
    assert {b, [], _} = State.merge(b, State.extract(c, old_b.replica, old_b.context))

    # IO.inspect(State.extract(a, b.replica, b.context))
    # IO.inspect(State.online_list(b))

    # assert [:bob] = keys(State.online_list(a))

    assert [:alice, :bob, :carol] = keys(State.online_list(b))
  end

  test "delta before transfer", config do
    a = new(:a, config)
    b = new(:b, config)
    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    adam = new_pid()

    a = State.join(a, alice, "lobby", :alice, %{meta: "foo"})
    a = State.join(a, adam, "lobby", :adam, %{meta: "foo"})

    # Node A sends updates to node B
    assert {b, [
      {{_, _, :adam}, _, _},
      {{_, _, :alice}, _, _}
    ], _} = State.merge(b, State.extract(a, b.replica, b.context))
    assert [:adam, :alice] = b |> State.online_list() |> keys()

    # Adam: foo changes to bar
    a = State.reset_delta(a)
    a = State.leave(a, adam, "lobby", :adam)
    a = State.join(a, adam, "lobby", :adam, %{meta: "bar"})

    # ^ THIS UPDATE IS NOT RECEIVED BY B (or there's a network delay)

    a = State.reset_delta(a)
    a = State.leave(a, adam, "lobby", :adam)
    a = State.join(a, adam, "lobby", :adam, %{meta: "baz"})

    # Node C comes up
    c = new(:c, config)
    {b, _, _} = State.replica_up(b, c.replica)
    {a, _, _} = State.replica_up(a, c.replica)
    {c, _, _} = State.replica_up(c, a.replica)
    {c, _, _} = State.replica_up(c, b.replica)

    # C gets most recent adam from delta update from A
    old_c = c # lets say the transfer req was sent before the delta merge, but the response arrived later
    assert {c,
      [{{_, _, :adam}, %{meta: "baz"}, _}],
      []
    } = State.merge(c, a.delta)

    # Now C receives transfer response from B (who has old alice - one missed update)
    assert {c, _, _} = State.merge(c, State.extract(b, old_c.replica, old_c.context))

    # (MatchError) no match of right hand side value: false
    # If we'd disable insert_new then we'd overwrite the value if an old value
  end

  test "joins are observed via other node", config do
    [a, b, c] = given_connected_cluster([:a, :b, :c], config)
    alice = new_pid()
    bob = new_pid()
    a = State.join(a, alice, "lobby", :alice)
    # the below join is just so that node c has some context from node a
    {c, [{{_, _, :alice}, _, _}], []} =
        State.merge(c, State.extract(a, c.replica, c.context))

    # netsplit between a and c
    {a, [], []} = State.replica_down(a, {:c, 1})
    {c, [], [{{_, _, :alice}, _, _}]} = State.replica_down(c, {:a, 1})

    a = State.join(a, bob, "lobby", :bob)
    {b, [{{_, _, :bob}, _, _}, {{_, _, :alice}, _, _}], []} =
        State.merge(b, State.extract(a, b.replica, b.context))

    assert {_, [{{_, _, :bob}, _, _}], []} =
      State.merge(c, State.extract(b, c.replica, c.context))
  end

  test "removes are observed via other node", config do
    [a, b, c] = given_connected_cluster([:a, :b, :c], config)
    alice = new_pid()
    bob = new_pid()
    a = State.join(a, alice, "lobby", :alice)
    {c, [{{_, _, :alice}, _, _}], []} =
        State.merge(c, State.extract(a, c.replica, c.context))

    # netsplit between a and c
    {a, [], []} = State.replica_down(a, {:c, 1})
    {c, [], [{{_, _, :alice}, _, _}]} = State.replica_down(c, {:a, 1})

    a = State.join(a, bob, "lobby", :bob)
    {b, [{{_, _, :bob}, _, _}, {{_, _, :alice}, _, _}], []} =
        State.merge(b, State.extract(a, b.replica, b.context))
    {c, [{{_, _, :bob}, _, _}], []} =
      State.merge(c, State.extract(b, c.replica, c.context))

    a = State.leave(a, bob, "lobby", :bob)
    {b, [], [{{_, _, :bob}, _, _}]} =
        State.merge(b, State.extract(a, b.replica, b.context))

    assert {_, [], [{{_, _, :bob}, _, _}]} =
        State.merge(c, State.extract(b, c.replica, c.context))
  end

  test "get_by_pid", config do
    pid = self()
    state = new(:node1, config)

    assert State.get_by_pid(state, pid) == []
    state = State.join(state, pid, "topic", "key1", %{})
    assert [{{"topic", ^pid, "key1"}, %{}, {{:node1, 1}, 1}}] =
           State.get_by_pid(state, pid)

    assert {{"topic", ^pid, "key1"}, %{}, {{:node1, 1}, 1}} =
           State.get_by_pid(state, pid, "topic", "key1")

    assert State.get_by_pid(state, pid, "notopic", "key1") == nil
    assert State.get_by_pid(state, pid, "notopic", "nokey") == nil
  end

  test "get_by_key", config do
    pid = self()
    pid2 = spawn(fn -> Process.sleep(:infinity) end)
    state = new(:node1, config)

    assert State.get_by_key(state, "topic", "key1") == []
    state = State.join(state, pid, "topic", "key1", %{device: :browser})
    state = State.join(state, pid2, "topic", "key1", %{device: :ios})
    state = State.join(state, pid2, "topic", "key2", %{device: :ios})

    assert [{^pid, %{device: :browser}}, {_pid2, %{device: :ios}}] =
           State.get_by_key(state, "topic", "key1")

    assert State.get_by_key(state, "another_topic", "key1") == []
    assert State.get_by_key(state, "topic", "another_key") == []
  end

  test "get_by_topic", config do
    pid = self()
    state = new(:node1, config)
    state2 = new(:node2, config)
    state3 = new(:node3, config)
    {state, _, _} = State.replica_up(state, {:node2, 1})
    {state, _, _} = State.replica_up(state, {:node3, 1})

    {state2, _, _} = State.replica_up(state2, {:node1, 1})
    {state2, _, _} = State.replica_up(state2, {:node3, 1})

    {state3, _, _} = State.replica_up(state3, {:node1, 1})
    {state3, _, _} = State.replica_up(state3, {:node2, 1})

    assert state.context ==
      %{{:node2, 1} => 0, {:node3, 1} => 0, {:node1, 1} => 0}
    assert state2.context ==
      %{{:node1, 1} => 0, {:node3, 1} => 0, {:node2, 1} => 0}
    assert state3.context ==
      %{{:node1, 1} => 0, {:node2, 1} => 0, {:node3, 1} => 0}

    user2 = new_pid()
    user3 = new_pid()

    assert [] = State.get_by_topic(state, "topic")
    state = State.join(state, pid, "topic", "key1", %{})
    state = State.join(state, pid, "topic", "key2", %{})
    state2 = State.join(state2, user2, "topic", "user2", %{})
    state3 = State.join(state3, user3, "topic", "user3", %{})

    # all replicas online
    assert [{"key1", %{}}, {"key2", %{}}] =
           State.get_by_topic(state, "topic")

    {state, _, _} = State.merge(state, State.extract(state2, state.replica, state.context))
    {state, _, _} = State.merge(state, State.extract(state3, state.replica, state.context))
    assert [{"key1", %{}}, {"key2", %{}}, {"user2", %{}}, {"user3", %{}}] =
           State.get_by_topic(state, "topic")

    # one replica offline
    {state, _, _} = State.replica_down(state, state2.replica)
    assert [{"key1", %{}}, {"key2", %{}}, {"user3", %{}}] =
      State.get_by_topic(state, "topic")

    # two replicas offline
    {state, _, _} = State.replica_down(state, state3.replica)
    assert [{"key1", %{}}, {"key2", %{}}] = State.get_by_topic(state, "topic")

    assert [] = State.get_by_topic(state, "another:topic")
  end

  test "remove_down_replicas", config do
    state1 = new(:node1, config)
    state2 = new(:node2, config)
    {state1, _, _} = State.replica_up(state1, state2.replica)
    {state2, _, _} = State.replica_up(state2, state1.replica)

    alice = new_pid()
    bob = new_pid()

    state1 = State.join(state1, alice, "lobby", :alice)
    state2 = State.join(state2, bob, "lobby", :bob)
    {state2, _, _} = State.merge(state2, State.extract(state1, state2.replica, state2.context))
    assert keys(State.online_list(state2)) == [:alice, :bob]

    {state2, _, _} = State.replica_down(state2, {:node1, 1})
    assert [{^alice, "lobby", :alice},
            {^bob, "lobby", :bob}] = tab2list(state2.pids)
    assert [{_, {"lobby", ^alice, :alice}},
            {_, {"lobby", ^bob, :bob}}] = tab2list(state2.tags)

    state2 = State.remove_down_replicas(state2, {:node1, 1})
    assert [{^bob, "lobby", :bob}] = tab2list(state2.pids)
    assert [{_, {"lobby", ^bob, :bob}}] = tab2list(state2.tags)

    {state2, _, _} = State.replica_up(state2, {:node1, 1})
    assert keys(State.online_list(state2)) == [:bob]
  end

  test "basic deltas", config do
    a = new(:a, config)
    b = new(:b, config)

    {a, _, _} = State.replica_up(a, b.replica)
    {b, _, _} = State.replica_up(b, a.replica)

    alice = new_pid()
    bob = new_pid()

    a = State.join(a, alice, "lobby", :alice)
    b = State.join(b, bob, "lobby", :bob)

    assert {b, [{{_, _, :alice}, _, _}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 1, {:b, 1} => 1}} = State.clocks(b)

    a = State.reset_delta(a)
    a = State.leave(a, alice, "lobby", :alice)

    assert {b, [], [{{_, _, :alice}, _, _}]} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 2, {:b, 1} => 1}} = State.clocks(b)

    a = State.join(a, alice, "lobby", :alice)
    assert {b, [{{_, _, :alice}, _, _}], []} = State.merge(b, a.delta)
    assert {{:b, 1}, %{{:a, 1} => 3, {:b, 1} => 1}} = State.clocks(b)
    assert Enum.all?(Enum.map(b.clouds, fn {_, cloud} -> Enum.empty?(cloud) end))
  end

  test "deltas are not merged for non-contiguous ranges", config do
    s1 = new(:s1, config)
    s2 = State.join(s1, new_pid(), "lobby", "user1", %{})
    s3 = State.join(s2, new_pid(), "lobby", "user2", %{})
    s4 = State.join(State.reset_delta(s3), new_pid(), "lobby", "user3", %{})

    assert State.merge_deltas(s2.delta, s4.delta) == {:error, :not_contiguous}
    assert State.merge_deltas(s4.delta, s2.delta) == {:error, :not_contiguous}
  end

  test "extracted state context contains only replicas known to remote replica",
    config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    s3 = new(:s3, config)
    {s1, _, _} = State.replica_up(s1, s2.replica)
    {s2, _, _} = State.replica_up(s2, s1.replica)
    {s2, _, _} = State.replica_up(s2, s3.replica)
    s1 = State.join(s1, new_pid(), "lobby", "user1", %{})
    s2 = State.join(s2, new_pid(), "lobby", "user2", %{})
    s3 = State.join(s3, new_pid(), "lobby", "user3", %{})
    {s1, _, _} = State.merge(s1, s2.delta)
    {s2, _, _} = State.merge(s2, s1.delta)
    {s2, _, _} = State.merge(s2, s3.delta)

    {extracted, _} = State.extract(s2, s1.replica, s1.context)

    assert extracted.context == %{{:s1, 1} => 1, {:s2, 1} => 1}
  end

  test "merging deltas", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    user1 = new_pid()
    user2 = new_pid()

    s1 = State.join(s1, user1, "lobby", "user1", %{})
    s1 = State.join(s1, user1, "private", "user1", %{})
    s2 = State.join(s2, user2, "lobby", "user2", %{})
    s2 = State.join(s2, user2, "private", "user2", %{})

    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    assert delta1.values == %{
      {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
      {{:s1, 1}, 2} => {user1, "private", "user1", %{}},
      {{:s2, 1}, 1} => {user2, "lobby", "user2", %{}},
      {{:s2, 1}, 2} => {user2, "private", "user2", %{}}
    }
    assert sorted_clouds(delta1.clouds) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]
  end

  test "merging deltas with removes", config do
    s1 = new(:s1, config)
    s2 = new(:s2, config)
    user1 = new_pid()
    {s1, _, _} = State.replica_up(s1, s2.replica)
    {s2, _, _} = State.replica_up(s2, s1.replica)

    # concurrent add wins
    s1 = State.join(s1, user1, "lobby", "user1", %{})
    s1 = State.join(s1, user1, "private", "user1", %{})
    s2 = State.join(s2, user1, "lobby", "user1", %{})
    s2 = State.leave(s2, user1, "lobby", "user1")

    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    s1 = %State{s1 | delta: delta1}
    assert delta1.values == %{
      {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
      {{:s1, 1}, 2} => {user1, "private", "user1", %{}},
    }
    assert sorted_clouds(delta1.clouds) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}]

    # merging duplicates maintains delta
    assert {:ok, ^delta1} = State.merge_deltas(delta1, s2.delta)

    {s2, _, _} = State.merge(s2, s1.delta)
    s2 = State.leave(s2, user1, "private", "user1")

    # observed remove
    {:ok, delta1} = State.merge_deltas(s1.delta, s2.delta)
    assert delta1.values == %{
      {{:s1, 1}, 1} => {user1, "lobby", "user1", %{}},
    }
    # maintains tombstone
    assert sorted_clouds(delta1.clouds) ==
      [{{:s1, 1}, 1}, {{:s1, 1}, 2}, {{:s2, 1}, 1}, {{:s2, 1}, 2}, {{:s2, 1}, 3}]
  end

  defp given_connected_cluster(nodes, config) do
    states = Enum.map(nodes, fn n -> new(n, config) end)
    replicas = Enum.map(states, fn s -> s.replica end)

    Enum.map(states, fn s ->
      Enum.reduce(replicas, s, fn replica, acc ->
        case acc.replica == replica do
          true -> acc
          false -> State.replica_up(acc, replica) |> elem(0)
        end
      end)
    end)
  end
end
