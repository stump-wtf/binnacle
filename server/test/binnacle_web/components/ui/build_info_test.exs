defmodule BinnacleWeb.Ui.BuildInfoTest do
  # The footer's build stamp is the one thing on screen that claims "this is
  # the commit you are looking at". A stamp that links somewhere that 404s is
  # worse than no stamp — it looks authoritative and is not.
  #
  # @joestump 08/21/2026 - Added while reviewing #70. The component guarded on
  #   truthiness alone, and both "unknown" (the Dockerfile's ARG default) and
  #   "" (an empty build-arg) are truthy in Elixir, so a local build rendered a
  #   link to /commit/unknown.

  use BinnacleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BinnacleWeb.Ui.Feedback

  defp stamp(sha), do: render_component(&Feedback.build_info/1, sha: sha)

  describe "a build with no real SHA" do
    for sha <- [nil, "", "   ", "unknown", "UNKNOWN"] do
      test "renders nothing for #{inspect(sha)}" do
        html = stamp(unquote(sha))

        refute html =~ "<a"
        refute html =~ "/commit/"
      end
    end
  end

  describe "a real SHA" do
    @sha "08f5ac3b8d481e4789e586d74e11e4351ef81c97"

    test "links to the commit on the canonical Gitea host" do
      html = stamp(@sha)

      assert html =~ "https://gitea.stump.rocks/stump.wtf/binnacle/commit/#{@sha}"
    end

    test "shows a short SHA but keeps the full one reachable" do
      html = stamp(@sha)

      assert html =~ String.slice(@sha, 0, 12)
      # A 40-character hash across a wall display is noise; the full value
      # stays in the title so it is still copyable.
      assert html =~ ~s(title="#{@sha}")
      refute html =~ ">#{@sha}<"
    end

    test "does not hand the target window a reference back to this one" do
      html = stamp(@sha)

      assert html =~ ~s(rel="noopener)
    end
  end
end
