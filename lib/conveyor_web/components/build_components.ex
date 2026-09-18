defmodule ConveyorWeb.BuildComponents do
  @moduledoc "Shared UI pieces for builds: status pills, tag chips, counters, time displays."
  use Phoenix.Component

  import ConveyorWeb.CoreComponents, only: [icon: 1]

  alias ConveyorWeb.Format

  @doc "A status pill with a colour and, for running builds, a pulse."
  attr :status, :string, required: true
  attr :exit_code_name, :string, default: nil
  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :string, default: nil

  def status_pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-full font-medium whitespace-nowrap",
        size_classes(@size),
        status_classes(@status),
        @class
      ]}
      data-status={@status}
      title={Conveyor.Ingest.Status.category(@exit_code_name) || @status}
    >
      <span class={[
        "size-1.5 rounded-full",
        dot_classes(@status),
        @status == "in_progress" && "animate-pulse"
      ]}></span>
      {status_label(@status)}
    </span>
    """
  end

  @doc "Renders tag chips, collapsing after `max`."
  attr :tags, :map, default: %{}
  attr :max, :integer, default: 4
  attr :class, :string, default: nil

  def tag_chips(assigns) do
    tags =
      assigns.tags
      |> Enum.reject(fn {k, _} ->
        k in ~w(command bazel_version host user build_host build_user)
      end)
      |> Enum.sort()

    {shown, hidden} = Enum.split(tags, assigns.max)
    assigns = assign(assigns, shown: shown, hidden: hidden)

    ~H"""
    <span :if={@shown != []} class={["inline-flex flex-wrap gap-1", @class]}>
      <span
        :for={{k, v} <- @shown}
        class="inline-flex max-w-48 truncate rounded bg-base-200 px-1.5 py-0.5 font-mono text-[11px] text-base-content/80"
        title={"#{k}=#{v}"}
      >
        <span class="text-base-content/50">{k}=</span>{v}
      </span>
      <span
        :if={@hidden != []}
        class="rounded bg-base-200 px-1.5 py-0.5 text-[11px] text-base-content/60"
        title={Enum.map_join(@hidden, "\n", fn {k, v} -> "#{k}=#{v}" end)}
      >
        +{length(@hidden)}
      </span>
    </span>
    """
  end

  @doc "Duration that keeps ticking while the build runs."
  attr :invocation, :map, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  def live_duration(assigns) do
    ~H"""
    <span
      id={@id || "duration-#{@invocation.id}"}
      phx-hook="LiveTime"
      phx-update="ignore"
      class={["tabular-nums", @class]}
      data-started={Format.iso(@invocation.started_at)}
      data-finished={Format.iso(@invocation.finished_at)}
    >
      {Format.duration(@invocation.duration_ms)}
    </span>
    """
  end

  @doc "Relative timestamp (`5m ago`) with an absolute title."
  attr :at, :any, required: true
  attr :id, :string, required: true
  attr :class, :string, default: nil

  def relative_time(assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook="LiveTime"
      phx-update="ignore"
      data-mode="relative"
      data-started={Format.iso(@at)}
      datetime={Format.iso(@at)}
      title={Format.iso(@at)}
      class={@class}
    >
      {Format.relative(@at, DateTime.utc_now())}
    </time>
    """
  end

  @doc "Pass/fail counters like `12 ✓ 1 ✗`."
  attr :ok, :integer, default: 0
  attr :failed, :integer, default: 0
  attr :extra, :integer, default: 0
  attr :extra_label, :string, default: "flaky"
  attr :title, :string, default: nil

  def counter(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1.5 whitespace-nowrap font-mono text-xs tabular-nums"
      title={@title}
    >
      <span
        :if={@ok > 0 or (@failed == 0 and @extra == 0)}
        class="text-emerald-600 dark:text-emerald-400"
      >{@ok} <.icon name="hero-check-micro" class="size-3 inline" /></span>
      <span :if={@failed > 0} class="text-rose-600 dark:text-rose-400">{@failed}
      <.icon name="hero-x-mark-micro" class="size-3 inline" /></span>
      <span :if={@extra > 0} class="text-amber-600 dark:text-amber-400" title={@extra_label}>{@extra} ~</span>
    </span>
    """
  end

  @doc "A small labelled stat used in headers and overview cards."
  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def stat(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <div class="text-[11px] uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="truncate font-medium tabular-nums">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Empty state block."
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  slot :inner_block

  def empty(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-2 py-16 text-center text-base-content/60">
      <.icon name={@icon} class="size-8 opacity-50" />
      <p class="font-medium text-base-content/80">{@title}</p>
      <div class="max-w-md text-sm">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  def status_label("in_progress"), do: "running"
  def status_label(status), do: status

  defp size_classes("xs"), do: "px-1.5 py-0 text-[10px]"
  defp size_classes("sm"), do: "px-2 py-0.5 text-xs"
  defp size_classes("md"), do: "px-2.5 py-1 text-sm"

  defp status_classes("succeeded"),
    do:
      "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300 ring-1 ring-inset ring-emerald-500/30"

  defp status_classes("failed"),
    do: "bg-rose-500/10 text-rose-700 dark:text-rose-300 ring-1 ring-inset ring-rose-500/30"

  defp status_classes("in_progress"),
    do: "bg-sky-500/10 text-sky-700 dark:text-sky-300 ring-1 ring-inset ring-sky-500/30"

  defp status_classes("aborted"),
    do: "bg-amber-500/10 text-amber-700 dark:text-amber-300 ring-1 ring-inset ring-amber-500/30"

  defp status_classes(_),
    do: "bg-base-content/5 text-base-content/70 ring-1 ring-inset ring-base-content/15"

  defp dot_classes("succeeded"), do: "bg-emerald-500"
  defp dot_classes("failed"), do: "bg-rose-500"
  defp dot_classes("in_progress"), do: "bg-sky-500"
  defp dot_classes("aborted"), do: "bg-amber-500"
  defp dot_classes(_), do: "bg-base-content/40"
end
