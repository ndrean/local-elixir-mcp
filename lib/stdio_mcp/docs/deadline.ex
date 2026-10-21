defmodule StdioMcp.Docs.Deadline do
  @moduledoc "Bounds foreground work without cancelling supervised ingestion jobs."

  def after_ms(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def remaining do
    case Process.get(:search_deadline) do
      nil -> :infinity
      deadline -> remaining(deadline)
    end
  end

  def run(deadline, work) do
    task =
      Task.Supervisor.async_nolink(StdioMcp.TaskSupervisor, fn ->
        Process.put(:search_deadline, deadline)
        work.()
      end)

    case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> {:error, :deadline_exceeded}
    end
  end
end
