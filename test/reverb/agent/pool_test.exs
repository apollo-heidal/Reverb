defmodule Reverb.Agent.PoolTest do
  use ExUnit.Case, async: false

  alias Reverb.Agent.Pool

  setup do
    start_supervised!(Pool)
    :ok
  end

  describe "fallback_chain/0" do
    test "returns at least the primary adapter/model pair" do
      chain = Pool.fallback_chain()
      assert is_list(chain)
      assert length(chain) >= 1
      {adapter, model} = hd(chain)
      assert is_atom(adapter)
      assert is_binary(model)
    end
  end

  describe "primary/0" do
    test "returns the first element of the chain" do
      assert Pool.primary() == hd(Pool.fallback_chain())
    end
  end

  describe "health tracking" do
    test "mark_ok resets consecutive failures" do
      Pool.mark_failed(:opencode, :timeout)
      Pool.mark_failed(:opencode, :timeout)
      assert Pool.adapter_healthy?(:opencode)

      Pool.mark_ok(:opencode)

      status = Pool.status()
      {_, opencode_entry} = Enum.find(status.adapters, fn {a, _} -> a == :opencode end)
      assert opencode_entry.consecutive_failures == 0
    end

    test "adapter becomes unhealthy after max consecutive failures" do
      for _ <- 1..3 do
        Pool.mark_failed(:opencode, :timeout)
      end

      refute Pool.adapter_healthy?(:opencode)
    end

    test "rate limiting marks adapter as unavailable" do
      assert Pool.available?(:opencode)

      Pool.mark_rate_limited(:opencode, 60)
      refute Pool.available?(:opencode)
    end
  end

  describe "next_after/1" do
    test "returns next healthy pair in the chain" do
      chain = Pool.fallback_chain()
      primary = hd(chain)

      result = Pool.next_after(primary)

      if length(chain) > 1 do
        assert result == Enum.at(chain, 1)
      else
        assert result == nil
      end
    end

    test "skips unhealthy adapters" do
      chain = Pool.fallback_chain()
      primary = hd(chain)

      for _ <- 1..3 do
        Pool.mark_failed(:opencode, :timeout)
      end

      result = Pool.next_after(primary)

      if length(chain) > 1 do
        {adapter, _model} = result
        assert adapter != :opencode
      end
    end

    test "returns nil when chain is exhausted" do
      Pool.reset()

      chain = Pool.fallback_chain()
      last = List.last(chain)

      assert Pool.next_after(last) == nil
    end
  end

  describe "reset/0" do
    test "clears all health state" do
      for _ <- 1..3, do: Pool.mark_failed(:opencode, :timeout)
      refute Pool.adapter_healthy?(:opencode)

      Pool.reset()
      assert Pool.adapter_healthy?(:opencode)
    end
  end
end
