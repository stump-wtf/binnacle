defmodule BinnacleWeb.HostJSON do
  # Wire serialization of hosts (SPEC-0001 REQ read-only-api).
  #
  # @joestump-agent 08/19/2026 - Initial version for SPEC-0001.

  alias BinnacleWeb.GuestJSON

  def host(host) do
    %{
      key: host.key,
      site: host.site,
      status: host.status,
      stale: host.stale,
      telemetry: host.telemetry,
      metrics: host.sample && metrics(host.sample),
      hardware: hardware(host.hardware),
      guests: Enum.map(host.guests, &GuestJSON.guest/1)
    }
  end

  def show(%{host: host}) do
    %{
      key: host.key,
      site: host.site,
      status: host.status,
      stale: host.stale,
      telemetry: host.telemetry
    }
    |> Map.merge(%{metrics: host.sample && metrics(host.sample)})
    |> Map.merge(%{series: host.series})
    |> Map.merge(%{
      hardware: hardware(host.hardware),
      guests: Enum.map(host.guests, &GuestJSON.guest/1)
    })
  end

  defp metrics(sample) do
    %{
      at: sample.at,
      cpu: sample.cpu,
      gpu: sample.gpu,
      memory: sample.memory,
      disk: sample.disk,
      cpu_temp: sample.cpu_temp,
      gpu_temp: sample.gpu_temp,
      hdd_temp: sample.hdd_temp
    }
  end

  def hardware(devices) do
    Enum.map(devices, fn device ->
      %{
        name: device.name,
        kind: device.kind,
        model: device.model,
        passthrough: device.passthrough
      }
    end)
  end
end
