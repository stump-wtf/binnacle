defmodule Binnacle.Fleet.Sampler do
  @moduledoc """
  The metrics sampler — pure functions from a node's previous sample and the
  tick counter to its next sample.

  **This is the bridge, not the destination.** Until the Proxmox/UniFi/Docker
  discovery story lands (SPEC-0001), the fleet context feeds these plausible,
  drifting readings into the history so the overview, the meters, and the
  trend lines are exercised against realistic data. The sampler's shape is
  deliberately the same as a real poller's: `(node, tick) -> Sample`, so
  swapping it for live probes is a drop-in change in `Binnacle.Fleet`.

  Readings drift on slow sinusoids with per-node phase offsets plus a little
  noise, so trend lines show load coming and going rather than jitter.
  """

  alias Binnacle.Fleet.Model.Sample

  @doc "Sample a host's hardware for a tick. Seed derives per-node variation."
  @spec sample_host(String.t(), integer(), Sample.t() | nil, keyword()) :: Sample.t()
  def sample_host(key, tick, prev, opts \\ []) do
    seed = opts[:seed] || :erlang.phash2(key)

    base = fn offset, lo, hi ->
      mid = (lo + hi) / 2
      span = (hi - lo) / 2

      mid + span * :math.sin((tick + seed + offset) / 23) +
        noise(seed + tick + offset) * span * 0.08
    end

    %Sample{
      at: DateTime.utc_now(),
      cpu: clamp(base.(0, 8, 78)),
      gpu: nil,
      memory: clamp(base.(7, 30, 74)),
      disk: clamp(base.(11, 18, 52)),
      cpu_temp: clamp(base.(3, 40, 74)),
      gpu_temp: nil,
      hdd_temp: clamp(base.(5, 28, 42))
    }
    |> merge_prev(prev)
  end

  @doc """
  Sample the one hot host — the gallery's `ogma` pattern: CPU and package
  temperature pushing their thresholds, so the overview has a real degraded
  state to show and the trend lines have a story to tell.
  """
  @spec sample_hot_host(String.t(), integer(), Sample.t() | nil, keyword()) :: Sample.t()
  def sample_hot_host(key, tick, prev, opts \\ []) do
    key
    |> sample_host(tick, prev, opts)
    |> Map.merge(%{
      cpu: clamp(74 + 16 * :math.sin((tick + :erlang.phash2(key)) / 17)),
      memory: clamp(72 + 12 * :math.sin((tick + 40) / 29)),
      cpu_temp: clamp(72 + 14 * :math.sin((tick + 9) / 19))
    })
  end

  @doc """
  Sample a silent host — powered off or not answering. Returns nil: the gap in
  the history *is* the signal, and the sparkline breaks rather than draws flat.
  """
  @spec sample_silent_host() :: nil
  def sample_silent_host, do: nil

  defp merge_prev(sample, nil), do: sample

  defp merge_prev(sample, %Sample{} = prev) do
    # Smooth toward the new value so a single noisy reading does not sawtooth
    # the trend line: each sample is 70% new signal, 30% previous level.
    for key <- [:cpu, :gpu, :memory, :disk, :cpu_temp, :gpu_temp, :hdd_temp],
        reduce: sample do
      acc ->
        new = Map.get(sample, key)
        old = Map.get(prev, key)

        Map.put(
          acc,
          key,
          case {new, old} do
            {nil, _} -> nil
            {new, nil} -> new
            {new, old} -> old * 0.3 + new * 0.7
          end
        )
    end
  end

  defp clamp(value) when value < 0, do: 0.0
  defp clamp(value) when value > 100, do: 100.0
  defp clamp(value), do: Float.round(value, 1)

  # Deterministic in n so the same tick renders identically on the server
  # and in tests; only the tick advancing moves it.
  defp noise(n), do: :erlang.phash2({n, n + 7}, 1_000) / 1_000 * 2 - 1
end
