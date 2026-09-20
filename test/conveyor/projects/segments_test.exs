defmodule Conveyor.Projects.SegmentsTest do
  use Conveyor.DataCase, async: true

  alias Conveyor.Projects
  alias Conveyor.Projects.Segments

  setup do
    {:ok, project} =
      Projects.create_project(%{slug: "seg-#{System.unique_integer([:positive])}", name: "Seg"})

    %{project: project}
  end

  test "projects fall back to the defaults until they save their own", %{project: project} do
    assert Segments.for_project(project) == Segments.defaults()

    {:ok, a} = Segments.create(project, %{"name" => "Main CI", "query" => "ci:true branch:main"})
    {:ok, b} = Segments.create(project, %{"name" => "Humans", "query" => "ai!=true"})
    assert a.position == 1 and b.position == 2

    assert Segments.for_project(project) == [
             %{"name" => "Main CI", "query" => "ci:true branch:main"},
             %{"name" => "Humans", "query" => "ai!=true"}
           ]

    {:ok, _} = Segments.delete(a)
    assert Segments.for_project(project) == [%{"name" => "Humans", "query" => "ai!=true"}]
    {:ok, _} = Segments.delete(b)
    assert Segments.for_project(project) == Segments.defaults()
  end

  test "validation: name, query syntax and uniqueness", %{project: project} do
    assert {:error, cs} = Segments.create(project, %{"name" => "  ", "query" => ""})
    assert %{name: [_]} = errors_on(cs)

    assert {:error, cs} = Segments.create(project, %{"name" => "a,b", "query" => ""})
    assert %{name: ["cannot contain commas"]} = errors_on(cs)

    assert {:error, cs} = Segments.create(project, %{"name" => "Bad", "query" => "ci:"})
    assert %{query: [_]} = errors_on(cs)

    assert {:ok, _} = Segments.create(project, %{"name" => "Same", "query" => "ci:true"})
    assert {:error, cs} = Segments.create(project, %{"name" => "Same", "query" => "ci:false"})
    assert %{name: [_]} = errors_on(cs)
  end

  test "move swaps neighbours and renumbers", %{project: project} do
    {:ok, a} = Segments.create(project, %{"name" => "A", "query" => ""})
    {:ok, b} = Segments.create(project, %{"name" => "B", "query" => ""})
    {:ok, c} = Segments.create(project, %{"name" => "C", "query" => ""})

    :ok = Segments.move(c, :up)
    assert Enum.map(Segments.list(project.id), & &1.name) == ~w(A C B)
    :ok = Segments.move(Segments.get!(a.id), :up)
    assert Enum.map(Segments.list(project.id), & &1.name) == ~w(A C B)
    :ok = Segments.move(Segments.get!(b.id), :down)
    assert Enum.map(Segments.list(project.id), & &1.name) == ~w(A C B)
    :ok = Segments.move(Segments.get!(a.id), :down)

    assert Enum.map(Segments.list(project.id), &{&1.name, &1.position}) == [
             {"C", 1},
             {"A", 2},
             {"B", 3}
           ]
  end
end
