defmodule Extensions.PostgresCdcRls.SynHandler do
  require Logger
  alias RealtimeWeb.Endpoint

  def on_process_unregistered(Extensions.PostgresCdcRls, name, _pid, _meta, reason) do
    Logger.info("PostgresCdcRls terminated: #{inspect(name)} #{node()}")

    broadcast_method =
      if reason == :syn_conflict_resolution do
        :broadcast
      else
        :local_broadcast
      end

    apply(Endpoint, broadcast_method, ["postgres_cdc:" <> name, "postgres_cdc_down", nil])
  end

  def resolve_registry_conflict(
        Extensions.PostgresCdcRls,
        name,
        {pid1, %{region: region}, time1},
        {pid2, _, time2}
      ) do
    fly_region = Realtime.PostgresCdc.aws_to_fly(region)

    fly_region_nodes =
      :syn.members(RegionNodes, fly_region)
      |> Enum.map(fn {_, [node: node]} -> node end)

    {keep, stop} =
      Enum.filter([pid1, pid2], fn pid ->
        Enum.member?(fly_region_nodes, node(pid))
      end)
      |> case do
        [pid] ->
          {pid, if(pid != pid1, do: pid1, else: pid2)}

        _ ->
          if time1 < time2 do
            {pid1, pid2}
          else
            {pid2, pid1}
          end
      end

    target = node(stop)
    Logger.warn("Resolving #{name} conflict, target: #{inspect(target)}")
    :rpc.call(target, DynamicSupervisor, :stop, [stop, :normal, 15_000])

    keep
  end
end
