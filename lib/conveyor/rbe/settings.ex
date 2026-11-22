defmodule Conveyor.Rbe.Settings do
  @moduledoc """
  A project's settings for the RBE opportunity report (`projects.settings["rbe"]`):

    * `cores`: `mnemonic → cores`, the owner's statement of what an action occupies
      (`{"TestRunner": 4}`); applied when a report is read, over whatever the parse
      estimated;
    * `pipeline_key`: optional, the build tag that identifies a pipeline run or a commit
      (`pipeline`, `commit`); racing time is also reported per value of it. Read when an
      hour is rolled, so a change applies to the hours rolled afterwards;
    * `tolerance_s`: how far apart two machines' clocks may be; executions that started
      within this many seconds of the first one's finish are reported as uncertain;
    * `cores_property`: how the project's builds declare cores per action on RBE:
      `names`, the exec (platform) property names to look for, in order (the first one a
      spawn carries with a readable value wins; names match in any case), and `unit`, how
      its value reads (`auto`, `cores` or `millicores`; `Conveyor.ExecLog.Cores`). Read
      when an execution log is parsed: the cores are stored per spawn as the exact
      source, so a change applies to the logs parsed afterwards
      (`Conveyor.Rbe.Reread` parses stored logs again).
  """
  alias Conveyor.Projects
  alias Conveyor.Projects.Project

  @tolerances [1, 2, 5, 10, 30, 60]
  @default_tolerance 2

  @units ~w(auto cores millicores)
  @max_names 8

  @type t :: %{
          cores: %{String.t() => float()},
          pipeline_key: String.t() | nil,
          tolerance_s: pos_integer(),
          cores_property: Conveyor.ExecLog.Cores.property()
        }

  @doc "The units a cores property can be read in."
  @spec units() :: [String.t()]
  def units, do: @units

  @doc "The tolerances a project can choose from (the bands a rollup keeps)."
  @spec tolerances() :: [pos_integer()]
  def tolerances, do: @tolerances

  @spec get(Project.t()) :: t()
  def get(%Project{settings: settings}) do
    rbe = Map.get(settings || %{}, "rbe", %{})

    %{
      cores: Map.get(rbe, "cores", %{}),
      pipeline_key: Map.get(rbe, "pipeline_key"),
      tolerance_s: Map.get(rbe, "tolerance_s", @default_tolerance),
      cores_property: cores_property(rbe)
    }
  end

  defp cores_property(rbe) do
    default = Conveyor.ExecLog.Cores.default_property()

    case Map.get(rbe, "cores_property") do
      %{"names" => [_ | _] = names, "unit" => unit} when unit in @units ->
        %{names: names, unit: unit}

      _ ->
        default
    end
  end

  @doc """
  Stores the settings from form text: `cores` as `Mnemonic=4, Other=0.5` (commas or
  lines), a tag key or blank, a tolerance, and how cores are declared: `cores_properties`
  as property names in order (commas or lines; blank restores the built-in list) and
  `cores_unit`. An attribute left out of `cores_properties` / `cores_unit` keeps what the
  project has.
  """
  @spec put(Project.t(), map()) :: {:ok, Project.t()} | {:error, String.t()}
  def put(%Project{} = project, attrs) do
    with {:ok, cores} <- parse_cores(attrs["cores"] || ""),
         {:ok, pipeline_key} <- parse_tag_key(attrs["pipeline_key"] || ""),
         {:ok, tolerance} <- parse_tolerance(attrs["tolerance_s"]),
         current = get(project).cores_property,
         {:ok, names} <- parse_names(attrs["cores_properties"], current.names),
         {:ok, unit} <- parse_unit(attrs["cores_unit"], current.unit) do
      rbe =
        %{"cores" => cores, "tolerance_s" => tolerance}
        |> then(&if(pipeline_key, do: Map.put(&1, "pipeline_key", pipeline_key), else: &1))
        |> then(fn rbe ->
          # The built-in declaration is not stored, so it follows the built-in list.
          if %{names: names, unit: unit} == Conveyor.ExecLog.Cores.default_property(),
            do: rbe,
            else: Map.put(rbe, "cores_property", %{"names" => names, "unit" => unit})
        end)

      case Projects.update_project(project, %{
             settings: Map.put(project.settings || %{}, "rbe", rbe)
           }) do
        {:ok, project} -> {:ok, project}
        {:error, _changeset} -> {:error, "could not save the settings"}
      end
    end
  end

  defp parse_cores(text) do
    text
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      with [name, value] <- String.split(pair, "=", parts: 2),
           name = String.trim(name),
           true <- name != "" and byte_size(name) <= 100,
           {cores, ""} <- Float.parse(String.trim(value)),
           true <- cores > 0 and cores <= 1024 do
        {:cont, {:ok, Map.put(acc, name, cores)}}
      else
        _ -> {:halt, {:error, "cores must look like Mnemonic=4, one per line or comma"}}
      end
    end)
  end

  defp parse_tag_key(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      key ->
        if Regex.match?(~r/^[a-z0-9_.-]{1,64}$/, key),
          do: {:ok, key},
          else: {:error, "the pipeline key is a tag key: lowercase letters, digits, . _ -"}
    end
  end

  defp parse_tolerance(nil), do: {:ok, @default_tolerance}
  defp parse_tolerance(""), do: {:ok, @default_tolerance}

  defp parse_tolerance(text) do
    case Integer.parse(to_string(text)) do
      {s, ""} when s in @tolerances -> {:ok, s}
      _ -> {:error, "the tolerance is one of #{Enum.join(@tolerances, ", ")} seconds"}
    end
  end

  @names_error "exec property names: 1 to #{@max_names}, one per line or comma, each up to 64 of letters, digits and . _ : / -"

  defp parse_names(nil, current), do: {:ok, current}

  defp parse_names(text, _current) when is_binary(text) do
    if String.trim(text) == "" do
      {:ok, Conveyor.ExecLog.Cores.default_property().names}
    else
      names =
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)

      distinct = Enum.uniq_by(names, &String.downcase/1)

      cond do
        length(names) > @max_names ->
          {:error, @names_error}

        not Enum.all?(names, &Regex.match?(~r/^[A-Za-z0-9_.:\/-]{1,64}$/, &1)) ->
          {:error, @names_error}

        length(distinct) != length(names) ->
          {:error, "an exec property name is listed twice (names match in any case)"}

        true ->
          {:ok, names}
      end
    end
  end

  defp parse_names(_other, _current), do: {:error, @names_error}

  defp parse_unit(nil, current), do: {:ok, current}
  defp parse_unit(unit, _current) when unit in @units, do: {:ok, unit}
  defp parse_unit(_unit, _current), do: {:error, "the unit is one of #{Enum.join(@units, ", ")}"}

  @doc "The property names as the form's text."
  @spec names_text(t()) :: String.t()
  def names_text(%{cores_property: %{names: names}}), do: Enum.join(names, ", ")

  @doc "The cores map as the form's text."
  @spec cores_text(t()) :: String.t()
  def cores_text(%{cores: cores}),
    do: cores |> Enum.sort() |> Enum.map_join("\n", fn {m, c} -> "#{m}=#{format(c)}" end)

  defp format(c) when c == trunc(c), do: Integer.to_string(trunc(c))
  defp format(c), do: Float.to_string(c)
end
