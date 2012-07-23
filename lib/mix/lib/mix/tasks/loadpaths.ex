defmodule Mix.Tasks.Loadpaths do
  use Mix.Task

  @moduledoc """
  Load the application and its dependencies paths.

  This task is not shown in `mix help` but it is part
  of mix public API and can be depended on.

  ## Configuration

  * `:load_paths` extra load paths to be added.
    They are added with lower priority than the app ones.

  """
  def run(_) do
    Mix.Task.run "deps.loadpaths"

    paths = Mix.project[:load_paths] || []
    Enum.each paths, Code.prepend_path(&1)

    ebin  = Mix.project[:compile_path] || "ebin"
    Code.prepend_path(ebin)
  end
end