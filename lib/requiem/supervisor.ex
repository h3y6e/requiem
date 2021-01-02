defmodule Requiem.Supervisor do
  @moduledoc """
  Root supervisor for all Requiem process tree.
  """
  use Supervisor
  alias Requiem.AddressTable
  alias Requiem.Config
  alias Requiem.QUIC
  alias Requiem.ConnectionRegistry
  alias Requiem.ConnectionSupervisor
  alias Requiem.DispatcherSupervisor
  alias Requiem.DispatcherRegistry
  alias Requiem.SenderSupervisor
  alias Requiem.SenderRegistry
  alias Requiem.SenderWorker

  @spec child_spec(module, atom) :: Supervisor.child_spec()
  def child_spec(handler, otp_app) do
    %{
      id: handler |> name(),
      start: {__MODULE__, :start_link, [handler, otp_app]},
      type: :supervisor
    }
  end

  @spec start_link(module, Keyword.t()) :: Supervisor.on_start()
  def start_link(handler, otp_app) do
    name = handler |> name()
    Supervisor.start_link(__MODULE__, [handler, otp_app], name: name)
  end

  @impl Supervisor
  def init([handler, otp_app]) do
    handler |> Config.init(otp_app)
    handler |> QUIC.setup()
    handler |> AddressTable.init()
    handler |> children() |> Supervisor.init(strategy: :one_for_one)
  end

  @spec children(module) :: [:supervisor.child_spec() | {module, term} | module]
  def children(handler) do
    [
      {Registry, keys: :unique, name: ConnectionRegistry.name(handler)},
      {Registry, keys: :unique, name: DispatcherRegistry.name(handler)},
      {Registry, keys: :unique, name: SenderRegistry.name(handler)},
      {ConnectionSupervisor, handler},
      {SenderSupervisor,
       [
         handler: handler,
         transport: handler |> transport_module(),
         buffering_interval: handler |> Config.get!(:sender_buffering_interval),
         number_of_senders: handler |> Config.get!(:sender_pool_size)
       ]},
      {DispatcherSupervisor,
       [
         handler: handler,
         sender: {SenderWorker, Config.get!(handler, :sender_pool_size)},
         token_secret: handler |> Config.get!(:token_secret),
         conn_id_secret: handler |> Config.get!(:connection_id_secret),
         number_of_dispatchers: handler |> Config.get!(:dispatcher_pool_size)
       ]},
      handler |> transport_spec()
    ]
  end

  defp transport_module(handler) do
    if handler |> Config.get!(:rust_transport) do
      Requiem.Transport.RustUDP
    else
      Requiem.Transport.GenUDP
    end
  end

  defp transport_spec(handler) do
    if handler |> Config.get!(:rust_transport) do
      {Requiem.Transport.RustUDP,
       [
         handler: handler,
         port: handler |> Config.get!(:port),
         number_of_dispatchers: handler |> Config.get!(:dispatcher_pool_size),
         event_capacity: handler |> Config.get!(:rust_transport_event_capacity),
         polling_timeout: handler |> Config.get!(:rust_transport_polling_timeout)
       ]}
    else
      {Requiem.Transport.GenUDP,
       [
         handler: handler,
         number_of_dispatchers: handler |> Config.get!(:dispatcher_pool_size),
         port: handler |> Config.get!(:port)
       ]}
    end
  end

  defp name(handler),
    do: Module.concat(handler, __MODULE__)
end
