# SPDX-FileCopyrightText: 2026 ash_discrete_business_events contributors <https://github.com/lukegalea/ash_discrete_business_events>
#
# SPDX-License-Identifier: MIT

defmodule AshDiscreteBusinessEvents.Simulation.IdentityTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshDiscreteBusinessEvents.Simulation.Identity

  # Pinned by test/simulation_identity_test.exs: re-rolling it is a
  # breaking change of every recorded comparison.
  @pinned_seed 7_051_631_904_854_280_433

  property "seed/1 is a pure function of the three inputs, in both option forms" do
    check all(
            subject <- string(:alphanumeric, min_length: 1, max_length: 32),
            random_stream_id <- string(:alphanumeric, min_length: 1, max_length: 32),
            replication_id <- integer(0..4_294_967_295),
            max_runs: 100
          ) do
      opts = [
        subject: subject,
        random_stream_id: random_stream_id,
        replication_id: replication_id
      ]

      assert Identity.seed(opts) == Identity.seed(opts)
      assert Identity.seed(opts) == Identity.seed(Map.new(opts))
    end
  end

  test "the candidate is refused as an input, whatever it would be" do
    base = [subject: "subject-1", random_stream_id: "arrivals", replication_id: 0]

    assert_raise ArgumentError, ~r/candidate_id/, fn ->
      Identity.seed(base ++ [candidate_id: "a"])
    end

    assert_raise ArgumentError, ~r/candidate_id/, fn ->
      Identity.seed(base ++ [candidate_id: "b"])
    end
  end

  property "draw/1 lands in [0.0, 1.0)" do
    check all(
            subject <- string(:alphanumeric, min_length: 1, max_length: 32),
            random_stream_id <- string(:alphanumeric, min_length: 1, max_length: 32),
            replication_id <- integer(0..4_294_967_295),
            max_runs: 100
          ) do
      draw =
        Identity.draw(
          subject: subject,
          random_stream_id: random_stream_id,
          replication_id: replication_id
        )

      assert is_float(draw)
      assert draw >= 0.0
      assert draw < 1.0
    end
  end

  test "replication ids 0..99 of one subject and stream give 100 distinct seeds" do
    seeds =
      for replication_id <- 0..99 do
        Identity.seed(
          subject: "subject-1",
          random_stream_id: "arrivals",
          replication_id: replication_id
        )
      end

    assert Enum.uniq(seeds) == seeds

    # The two pinned replications also draw differently.
    first = Identity.draw(subject: "subject-1", random_stream_id: "arrivals", replication_id: 0)

    second =
      Identity.draw(subject: "subject-1", random_stream_id: "arrivals", replication_id: 1)

    assert first != second
  end

  property "a different subject or stream gives a different seed" do
    check all(
            subject <- string(:alphanumeric, min_length: 1, max_length: 16),
            random_stream_id <- string(:alphanumeric, min_length: 1, max_length: 16),
            replication_id <- integer(0..65_535),
            max_runs: 50
          ) do
      opts = [
        subject: subject,
        random_stream_id: random_stream_id,
        replication_id: replication_id
      ]

      seed = Identity.seed(opts)

      assert seed != Identity.seed(Keyword.put(opts, :subject, subject <> "!"))

      assert seed !=
               Identity.seed(Keyword.put(opts, :random_stream_id, random_stream_id <> "!"))
    end
  end

  test ~S[length prefixes keep ("ab", "c") and ("a", "bc") apart] do
    left = Identity.seed(subject: "ab", random_stream_id: "c", replication_id: 0)
    right = Identity.seed(subject: "a", random_stream_id: "bc", replication_id: 0)

    assert left != right
  end

  describe "refusals" do
    test "a missing, nil, empty or wrongly-typed random_stream_id raises, naming the field" do
      for value <- [:missing, nil, "", 5] do
        opts =
          [subject: "subject-1", replication_id: 0]
          |> put_opt(:random_stream_id, value)

        assert_raise ArgumentError, ~r/random_stream_id/, fn ->
          Identity.seed(opts)
        end
      end
    end

    test "a missing, nil, empty or wrongly-typed subject raises, naming the field" do
      for value <- [:missing, nil, "", 5] do
        opts =
          [random_stream_id: "arrivals", replication_id: 0]
          |> put_opt(:subject, value)

        assert_raise ArgumentError, ~r/subject/, fn ->
          Identity.seed(opts)
        end
      end
    end

    test "a missing, nil, negative, fractional or binary replication_id raises, naming the field" do
      for value <- [:missing, nil, -1, 1.5, "1"] do
        opts =
          [subject: "subject-1", random_stream_id: "arrivals"]
          |> put_opt(:replication_id, value)

        assert_raise ArgumentError, ~r/replication_id/, fn ->
          Identity.seed(opts)
        end
      end
    end

    test "unknown keys raise, naming the key, in keyword and map form" do
      for unknown <- [:candidate_id, :snapshot_digest, :model_hash, :foo] do
        opts =
          [{unknown, "x"}, subject: "subject-1", random_stream_id: "arrivals", replication_id: 0]

        assert_raise ArgumentError, ~r/#{unknown}/, fn ->
          Identity.seed(opts)
        end
      end

      assert_raise ArgumentError, ~r/candidate_id/, fn ->
        Identity.seed(%{
          subject: "subject-1",
          random_stream_id: "arrivals",
          replication_id: 0,
          candidate_id: "a"
        })
      end
    end

    test "a non-keyword, non-map argument raises" do
      for bad <- [[1, 2, 3], nil] do
        # apply/3 keeps the type checker quiet: the argument can never
        # succeed against the contract, and refusing it IS the test.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        assert_raise ArgumentError, fn -> apply(Identity, :seed, [bad]) end
      end
    end
  end

  test "the pinned vector is stable" do
    opts = [subject: "subject-1", random_stream_id: "arrivals", replication_id: 0]

    assert Identity.seed(opts) == @pinned_seed
    assert Identity.seed(Map.new(opts)) == @pinned_seed

    assert Identity.draw(opts) == Bitwise.bsr(@pinned_seed, 11) / 9_007_199_254_740_992
  end

  defp put_opt(opts, _key, :missing), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
