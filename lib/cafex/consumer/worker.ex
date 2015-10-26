defmodule Cafex.Consumer.Worker do
  @behaviour :gen_fsm

  require Logger

  defmodule State do
    defstruct topic: nil,
              group: nil,
              partition: nil,
              broker: nil,
              zk_pid: nil,
              zk_path: nil,
              conn: nil,
              lock: {false, nil},
              buffer: [],
              hwm_offset: 0,
              batch_size: 50,
              manager: nil,
              handler: nil,
              handler_data: nil
  end

  alias Cafex.ZK.Lock
  alias Cafex.Connection
  alias Cafex.Protocol.Fetch
  alias Cafex.Protocol.Fetch.Request, as: FetchRequest
  alias Cafex.Consumer.Manager

  # ===================================================================
  # API
  # ===================================================================

  def start_link(manager, handler, topic, group, partition, broker, zk_pid, zk_path) do
    :gen_fsm.start_link __MODULE__, [manager, handler, topic, group, partition, broker, zk_pid, zk_path], []
  end

  def stop(pid) do
    :gen_fsm.sync_send_all_state_event pid, :stop, :infinity
  end

  # ===================================================================
  #  GenServer callbacks
  # ===================================================================

  def init([manager, handler, topic, group, partition, broker, zk_pid, zk_path]) do
    state = %State{topic: topic,
                   group: group,
                   partition: partition,
                   broker: broker,
                   manager: manager,
                   handler: handler,
                   zk_pid: zk_pid,
                   zk_path: zk_path}
    {:ok, :aquire_lock, state, 0}
  end

  @lock_timeout 60000 * 5

  def aquire_lock(:timeout, %{partition: partition,
                              zk_pid: pid,
                              zk_path: zk_path,
                              lock: lock} = state) do
    path = Path.join [zk_path, "locks", Integer.to_string(partition)]
    case lock do
      {false, nil}  -> Lock.aquire(pid, path, :infinity)
      {false, lock} -> Lock.reaquire(pid, path, lock, :infinity)
    end
    |> case do
      {:wait, _} ->
        {:next_state, :waiting_lock, state, @lock_timeout}
      {:ok, lock} ->
        {:next_state, :prepare, %{state | lock: {true, lock}}, 0}
    end
  end

  def waiting_lock(:timeout, state) do
    {:stop, :lock_timeout, state}
  end
  def waiting_lock({:lock_again, lock}, state) do
    {:next_state, :aquire_lock, %{state | lock: {false, lock}}, 0}
  end

  def prepare(:timeout, %{partition: partition,
                          broker: {host, port},
                          handler: {handler, args},
                          manager: manager} = state) do
    {:ok, conn} = Connection.start_link(host, port)
    {:ok, data} = handler.init(args)
    {:ok, {offset, _}} = Manager.offset_fetch(manager, partition)
    {:next_state, :consuming, %{state | conn: conn,
                                        hwm_offset: offset,
                                        handler: handler,
                                        handler_data: data}, 0}
  end

  def consuming(:timeout, state) do
    consume(state)
  end
  def consuming({:kafka_response, response}, state) do
    handle_fetch_response(response, state)
  end

  def waiting_messages(:timeout, state) do
    {:stop, :fetch_timeout, state}
  end
  def waiting_messages({:kafka_response, response}, state) do
    handle_fetch_response(response, state)
  end

	@doc false
	def handle_event(event, state_name, state_data) do
		{:stop, {:bad_event, state_name, event}, state_data}
	end

  def handle_sync_event(:stop, _from, _state_name, state) do
    {:stop, :normal, :ok, state}
  end

	@doc false
	def handle_info({:lock_again, lock}, state_name, state_data) do
    :gen_fsm.send_event self, {:lock_again, lock}
		{:next_state, state_name, state_data}
	end

	@doc false
	def terminate(_reason, _state_name, %{handler: handler,
                                        handler_data: data} = state_data) do
    close_connection(state_data)
    release_lock(state_data)
    if data, do: handler.terminate(data)
		:ok
	end

	@doc false
	def code_change(_old, state_name, state_data, _extra) do
		{:ok, state_name, state_data}
	end

  # ===================================================================
  #  Internal functions
  # ===================================================================

  defp close_connection(%{conn: nil}), do: :ok
  defp close_connection(%{conn: pid}), do: Connection.close(pid)

  defp release_lock(%{lock: {false, _}}), do: :ok
  defp release_lock(%{lock: {true, lock}, zk_pid: zk}), do: Lock.release(zk, lock)

  # TODO configurable
  @wait_time 100
  @min_bytes 32 * 1024
  @max_bytes 1024 * 1024

  defp fetch_messages(%{topic: topic,
                        partition: partition,
                        hwm_offset: offset,
                        conn: conn} = state) do
    # Logger.debug fn -> "Consumer[#{group}:#{topic}:#{partition}] fetching messages: offset = #{offset}" end
    request = %FetchRequest{max_wait_time: @wait_time,
                            min_bytes: @min_bytes,
                            topics: [{topic, [{partition, offset, @max_bytes}]}]}
    Connection.async_request(conn, request, Fetch, {:fsm, self})
    state
  end

  defp handle_fetch_response(response, %{topic: topic,
                                         partition: partition,
                                         buffer: buffer,
                                         hwm_offset: offset} = state) do
    case response do
      {:ok, %{topics: [{^topic, [%{error: :no_error, messages: messages, hwm_offset: hwm_offset}]}]}} ->
        {:ok, %{state | buffer: buffer ++ messages, hwm_offset: hwm_offset}}
      {:ok, %{topics: [{^topic, [%{error: :not_leader_for_partition = reason}]}]}} ->
        Logger.error "Failed to fetch new messages: #{inspect reason}, topic: #{topic}, partition: #{partition}, offset: #{offset}"
        {:error, :not_leader_for_partition, state}
      {:ok, %{topics: [{^topic, [%{error: reason}]}]}} ->
        Logger.error "Failed to fetch new messages: #{inspect reason}, topic: #{topic}, partition: #{partition}, offset: #{offset}"
        {:ok, state}
      {:error, reason} ->
        Logger.error "Failed to fetch new messages: #{inspect reason}, topic: #{topic}, partition: #{partition}, offset: #{offset}"
        {:ok, state}
    end
    |> case do
      {:ok, %{buffer: []} = state} -> {:next_state, :consuming, state, 1000}
      {:ok, state} -> {:next_state, :consuming, state, 0}
      {:error, reason, state} ->
        {:stop, reason, state}
    end
  end

  defp consume(%{batch_size: batch_size} = state) do
    state = %{buffer: buffer} = do_consume(batch_size, state)
    case length(buffer) < batch_size do
      true  ->
        state = fetch_messages(state)
        {:next_state, :waiting_messages, state}
      false ->
        {:next_state, :consuming, state, 0}
    end
  end

  defp do_consume(0, state), do: state
  defp do_consume(_, %{buffer: []} = state), do: state
  defp do_consume(c, %{buffer: [first|rest]} = state) do
    state = handle_message(first, state)
    do_consume(c - 1, %{state | buffer: rest})
  end

  defp handle_message(%{offset: offset} = message, %{manager: manager,
                                                     partition: partition,
                                                     handler: handler,
                                                     handler_data: handler_data} = state) do
    {:ok, data} = handler.consume(message, handler_data)
    Manager.offset_commit(manager, partition, offset + 1)
    %{state | handler_data: data}
  end
end
