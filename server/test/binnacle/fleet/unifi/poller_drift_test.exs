defmodule Binnacle.Fleet.Unifi.PollerDriftTest do
  # Governing: ADR-0002 (fleet taxonomy), SPEC-0001 REQ "Discovery Does Not
  # Invent Topology".
  #
  # The poller gained a second call — fetch_sites — purely to feed drift. The
  # contract that matters is that it is SECONDARY: it must never degrade or
  # crash the device poll, which is the thing the UI actually renders.
  #
  # @joestump 08/21/2026 - Added while reviewing #66, which wired fetch_sites
  #   in with no coverage of its failure paths.

  use ExUnit.Case, async: true

  alias Binnacle.Fleet.Model.Site
  alias Binnacle.Fleet.Unifi.Poller

  defp start_poller(fetch, fetch_sites) do
    start_supervised!(
      {Poller,
       site: "dub",
       base_url: "https://example.invalid",
       credential: %{username: "u", password: "p"},
       interval_ms: 60_000,
       fetch: fetch,
       fetch_sites: fetch_sites,
       sink: self()},
      id: {Poller, make_ref()}
    )
  end

  @devices {:ok, %{gateway: nil, devices: []}}

  test "site names ride along with a successful device poll" do
    start_poller(
      fn _, _, _ -> @devices end,
      fn _, _, _ -> {:ok, [%Site{slug: "default", kind: :home}]} end
    )

    assert_receive {:unifi, "dub", {:ok, result}}, 1_000
    assert result.site_names == ["default"]
    assert result.devices == []
  end

  test "a fetch_sites failure does not degrade the device poll" do
    start_poller(
      fn _, _, _ -> @devices end,
      fn _, _, _ -> {:error, "UniFi /api/self/sites answered HTTP 403"} end
    )

    assert_receive {:unifi, "dub", {:ok, result}}, 1_000
    assert result.site_names == nil, "a sites failure must read as unknown, not as no sites"
    assert Map.has_key?(result, :devices)
  end

  test "a device-poll failure is delivered as-is and skips the sites call" do
    parent = self()

    start_poller(
      fn _, _, _ -> {:error, "connection refused"} end,
      fn _, _, _ ->
        send(parent, :sites_called)
        {:ok, []}
      end
    )

    assert_receive {:unifi, "dub", {:error, "connection refused"}}, 1_000
    refute_receive :sites_called, 200
  end

  test "an unrecognised site shape is described, not raised on" do
    # to_string/1 on a map raises Protocol.UndefinedError, which took the
    # poller down mid-cycle and lost the device poll that had just succeeded.
    start_poller(
      fn _, _, _ -> @devices end,
      fn _, _, _ -> {:ok, [%{"desc" => "no name key"}, "plain-string"]} end
    )

    assert_receive {:unifi, "dub", {:ok, result}}, 1_000
    assert length(result.site_names) == 2
    assert Enum.all?(result.site_names, &is_binary/1)
    assert "plain-string" in result.site_names
  end
end
