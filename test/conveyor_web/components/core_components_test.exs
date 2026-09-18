defmodule ConveyorWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import ConveyorWeb.CoreComponents

  alias Phoenix.LiveView.JS

  defp render(template), do: rendered_to_string(template)

  test "flash renders title, message and close control" do
    assigns = %{}

    html =
      render(~H"""
      <.flash kind={:info} title="Saved" flash={%{"info" => "All good"}} id="f" />
      <.flash kind={:error} flash={%{"error" => "Boom"}} />
      <.flash kind={:info} flash={%{}}>hidden</.flash>
      """)

    assert html =~ "Saved" and html =~ "All good" and html =~ "Boom"
  end

  test "buttons render as button or link with variants" do
    assigns = %{}

    html =
      render(~H"""
      <.button>Plain</.button>
      <.button variant="primary">Primary</.button>
      <.button navigate="/x">Go</.button>
      """)

    assert html =~ ~s(<button) and html =~ "Primary" and html =~ ~s(href="/x")
  end

  test "inputs render every type" do
    assigns = %{
      form: to_form(%{"name" => "n", "ok" => true, "kind" => "a", "notes" => "t"}, as: :f)
    }

    html =
      render(~H"""
      <.input field={@form[:name]} label="Name" />
      <.input field={@form[:ok]} type="checkbox" label="Ok" />
      <.input field={@form[:kind]} type="select" label="Kind" options={[a: "a", b: "b"]} prompt="pick" />
      <.input field={@form[:notes]} type="textarea" label="Notes" />
      <.input name="h" value="1" type="hidden" />
      <.input name="e" value="" label="Err" errors={["is required"]} />
      <.input name="c" value="" type="checkbox" checked errors={["bad"]} />
      <.input name="s" value="" type="select" options={[]} errors={["bad"]} />
      <.input name="t" value="" type="textarea" errors={["bad"]} />
      """)

    assert html =~ ~s(name="f[name]") and html =~ "textarea" and html =~ "is required" and
             html =~ "pick"
  end

  test "inputs render errors from a changeset-backed form" do
    types = %{name: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(%{"name" => ""}, Map.keys(types))
      |> Ecto.Changeset.validate_required([:name])

    assigns = %{form: to_form(%{changeset | action: :validate}, as: :f)}
    html = render(~H|<.input field={@form[:name]} label="Name" />|)
    assert html =~ "can&#39;t be blank"
  end

  test "header, table, list and icon" do
    assigns = %{rows: [%{id: 1, name: "a"}, %{id: 2, name: "b"}]}

    html =
      render(~H"""
      <.header>
        Title<:subtitle>Sub</:subtitle><:actions>Act</:actions>
      </.header>
      <.table id="t" rows={@rows} row_click={fn _ -> JS.push("x") end}>
        <:col :let={r} label="Name">{r.name}</:col>
        <:action :let={r}>edit {r.id}</:action>
      </.table>
      <.table id="t2" rows={@rows} row_id={&"row-#{&1.id}"}>
        <:col :let={r} label="N">{r.name}</:col>
      </.table>
      <.list>
        <:item title="K">V</:item>
      </.list>
      <.icon name="hero-x-mark" class="size-3" />
      """)

    assert html =~ "Sub" and html =~ "edit 2" and html =~ ~s(id="row-1") and html =~ "hero-x-mark"
  end

  test "show and hide build JS commands" do
    assert %JS{ops: [_ | _]} = show("#a")
    assert %JS{ops: [_ | _]} = hide("#a")
  end

  test "translates errors with and without counts" do
    assert translate_error({"should be at least %{count} character(s)", [count: 3]}) =~ "3"
    assert translate_error({"is invalid", []}) == "is invalid"
    assert translate_errors([name: {"is blank", []}, other: {"x", []}], :name) == ["is blank"]
  end
end
