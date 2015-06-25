defmodule MarcoPolo.Protocol do
  require Integer
  import MarcoPolo.Protocol.BinaryHelpers
  alias MarcoPolo.Error
  alias MarcoPolo.Protocol.RecordSerialization

  @type encodable_term ::
    boolean
    | nil
    | binary
    | integer
    | iolist
    | {:short, integer}
    | {:int, integer}
    | {:long, integer}
    | {:raw, binary}

  @type sid :: non_neg_integer
  @type op_code :: non_neg_integer
  @type op_name :: atom

  @ok    <<0>>
  @error <<1>>
  @null  <<-1 :: int>>

  @doc """
  """
  def encode_op(op_name, args) do
    [req_code(op_name)|Enum.map(args, &encode_term/1)]
  end

  @doc """
  Serializes an Elixir term to an OrientDB term according to the binary
  protocol.

  Supported Elixir terms are:

    * booleans (`true` and `false`)
    * `nil`
    * binaries (hence strings)
    * integers (by default encoded as "int", but the size of the integer can be
      specified by "tagging" the integer, e.g., `{:short, 28}` or
      `{:long, 1000}`).
    * lists (assumed to be iolists)
    * raw bytes (with `{:raw, bytes}`)

  """
  @spec encode_term(encodable_term) :: iodata
  def encode_term(term)

  # Booleans.
  def encode_term(true),  do: <<1>>
  def encode_term(false), do: <<0>>

  # nil.
  def encode_term(nil), do: encode_term({:int, -1})

  # Strings and bytes.
  def encode_term(str) when is_binary(str), do: encode_term({:int, byte_size(str)}) <> str

  # Encoding an Elixir integer defaults to encoding an OrientDB int (4 bytes).
  def encode_term(i) when is_integer(i), do: encode_term({:int, i})

  # Typed integers (short, int and long) have to be tagged.
  def encode_term({:short, i}), do: <<i :: short>>
  def encode_term({:int, i}),   do: <<i :: int>>
  def encode_term({:long, i}),  do: <<i :: long>>

  # A list is assumed to be iodata and is converted to binary before being serialized.
  def encode_term(data) when is_list(data), do: [encode_term(IO.iodata_length(data)), data]

  # Raw bytes (that have no leading length, just the bytes).
  def encode_term({:raw, bytes}) when is_binary(bytes) or is_list(bytes), do: bytes

  # An entire record.
  def encode_term({:record, record}), do: encode_term(RecordSerialization.encode(record))

  # Modes (sync, async, no_response).
  def encode_term({:mode, :sync}),        do: <<0>>
  def encode_term({:mode, :async}),       do: <<0>>
  def encode_term({:mode, :no_response}), do: <<2>>

  @doc """
  """
  @spec parse_connection_header(binary) :: {:ok, sid, binary} | Error.t
  def parse_connection_header(@ok <> @null <> <<sid :: int, rest :: binary>>),
    do: {:ok, sid, rest}
  def parse_connection_header(@error <> @null <> rest),
    do: %Error{message: "error (binary dump: #{inspect rest})"}

  @doc """
  """
  @spec parse_resp(op_name, binary) :: {:ok, sid, binary, binary} | Error.t
  def parse_resp(op_name, data) do
    case parse_header(data) do
      {:ok, sid, rest} ->
        {:ok, sid, parse_resp_contents(op_name, rest)}
      {:server_error, rest} ->
        {errors, rest} = parse_errors(rest)
        {:error, Error.from_errors(errors)}
    end
  end

  @doc """
  """
  @spec parse_header(binary) :: {:ok, sid, binary} | Error.t
  def parse_header(data)

  def parse_header(@ok <> <<sid :: int, rest :: binary>>) do
    {:ok, sid, rest}
  end

  def parse_header(@error <> <<_sid :: int, rest :: binary>>) do
    {:server_error, rest}
  end

  @doc """
  """
  @spec parse(binary, atom) :: {binary, binary}
  def parse(<<length :: int, data :: binary>>, type) when type in [:string, :bytes] do
    length = bytes(length)
    <<parsed :: bits-size(length), rest :: binary>> = data
    {parsed, rest}
  end

  defp parse_errors(data, acc \\ [])

  defp parse_errors(<<1, rest :: binary>>, acc) do
    {class, rest}   = parse(rest, :string)
    {message, rest} = parse(rest, :string)
    parse_errors(rest, [{class, message}|acc])
  end

  defp parse_errors(<<0, rest :: binary>>, acc) do
    # What am I supposed to do with a Java binary dump of the exception?! :(
    {_dump, rest} = parse(rest, :bytes)
    {Enum.reverse(acc), rest}
  end

  defp parse_resp_contents(:db_create, <<>>) do
    []
  end

  defp parse_resp_contents(:db_exist, <<exists>>) do
    [exists == 1]
  end

  defp parse_resp_contents(:db_drop, <<>>) do
    []
  end

  defp parse_resp_contents(:db_size, <<size :: long>>) do
    [size]
  end

  defp parse_resp_contents(:db_countrecords, <<count :: long>>) do
    [count]
  end

  defp parse_resp_contents(:db_reload, <<num_of_clusters :: short, rest :: binary>>) do
    Enum.map_reduce 1..num_of_clusters, rest, fn _, acc ->
      {cluster_name, acc} = parse(acc, :string)
      <<cluster_id :: short, acc :: binary>> = acc
      {{cluster_name, cluster_id}, acc}
    end
  end

  defp parse_resp_contents(:record_load, data) do
    parse_resp_contents(:record_load, data, []) |> Enum.reverse
  end

  defp parse_resp_contents(:record_load, <<1, type, version :: int, rest :: binary>>, acc) do
    {record_content, rest} = parse(rest, :bytes)
    {class_name, fields} = RecordSerialization.decode(record_content)
    record = %MarcoPolo.Record{class: class_name, fields: fields, version: version}
    parse_resp_contents(:record_load, rest, [{record_type(type), record}|acc])
  end

  defp parse_resp_contents(:record_load, <<0>>, acc) do
    acc
  end

  defp parse_resp_contents(:record_create, <<cluster_id :: short, cluster_position :: long, record_version :: int, rest :: binary>>) do
    {"##{cluster_id}:#{cluster_position}", record_version, rest}
  end

  defp parse_resp_contents(:record_update, <<record_version :: int, rest :: binary>>) do
    {record_version, rest}
  end

  defp parse_resp_contents(:record_delete, <<1>>), do: true
  defp parse_resp_contents(:record_delete, <<0>>), do: false

  @null_result       ?n
  @list              ?l
  @set               ?s
  @single_record     ?r
  @serialized_result ?a

  defp parse_resp_contents(:command, data) do
    parse_resp_to_command(data)
  end

  defp parse_resp_to_command(<<type, nrecords :: int, rest :: binary>>) when type in [@list, @set] do
    # Records are encoded like this here:
    # (record-kind?:short)(record-type:byte)(cluster-id:short)(cluster-position:long)(record-version:int)(record-content:bytes)
    # because why not? I have no idea what record-kind is, this link:
    # https://groups.google.com/forum/#!searchin/orient-database/idempotent/orient-database/i3IXXVLCyNo/GJGPkGXtHF0J
    # is the closest I got to finding out more.
    {records, rest} = Enum.map_reduce List.duplicate(0, nrecords), rest, fn(_, acc) ->
      <<_unknown :: short, record_type, cluster_id :: short, cluster_position :: long, record_version :: int, acc :: binary>> = acc
      {record_content, acc} = parse(acc, :bytes)
      {class_name, fields} = RecordSerialization.decode(record_content)
      record = %MarcoPolo.Record{class: class_name, fields: fields, version: record_version}
      {{record_type(record_type), record}, acc}
    end

    # TODO find out why OrientDB shoves a 0 byte at the end of this list, not
    # mentioned in the docs :(
    <<0>> = rest

    records
  end

  defp parse_resp_to_command(<<@single_record, rest :: binary>>) do
    <<_unknown :: short, record_type, cluster_id :: short, cluster_position :: long, record_version :: int, rest :: binary>> = rest
    {record_content, rest} = parse(rest, :bytes)
    {class_name, fields} = RecordSerialization.decode(record_content)
    record = %MarcoPolo.Record{class: class_name, fields: fields, version: record_version}

    # TODO find out why OrientDB shoves a 0 byte at the end of this list, not
    # mentioned in the docs :(
    <<0>> = rest

    {record_type(record_type), record}
  end

  defp record_type(?d), do: :document

  defp req_code(:shutdown),                        do: 1
  defp req_code(:connect),                         do: 2
  defp req_code(:db_open),                         do: 3
  defp req_code(:db_create),                       do: 4
  defp req_code(:db_exist),                        do: 6
  defp req_code(:db_drop),                         do: 7
  defp req_code(:config_get),                      do: 70
  defp req_code(:config_set),                      do: 71
  defp req_code(:config_list),                     do: 72
  defp req_code(:db_list),                         do: 74
  defp req_code(:db_close),                        do: 5
  defp req_code(:db_size),                         do: 8
  defp req_code(:db_countrecords),                 do: 9
  defp req_code(:datacluster_copy),                do: 14
  defp req_code(:datacluster_lh_cluster_is_used),  do: 16
  defp req_code(:record_metadata),                 do: 29
  defp req_code(:record_load),                     do: 30
  defp req_code(:record_create),                   do: 31
  defp req_code(:record_update),                   do: 32
  defp req_code(:record_delete),                   do: 33
  defp req_code(:record_copy),                     do: 34
  defp req_code(:record_clean_out),                do: 38
  defp req_code(:positions_floor),                 do: 39
  defp req_code(:command),                         do: 41
  defp req_code(:positions_ceiling),               do: 42
  defp req_code(:tx_commit),                       do: 60
  defp req_code(:db_reload),                       do: 73
  defp req_code(:push_record),                     do: 79
  defp req_code(:push_distrib_config),             do: 80
  defp req_code(:db_copy),                         do: 90
  defp req_code(:replication),                     do: 91
  defp req_code(:cluster),                         do: 92
  defp req_code(:db_transfer),                     do: 93
  defp req_code(:db_freeze),                       do: 94
  defp req_code(:db_release),                      do: 95
  defp req_code(:create_sbtree_bonsai),            do: 110
  defp req_code(:sbtree_bonsai_get),               do: 111
  defp req_code(:sbtree_bonsai_first_key),         do: 112
  defp req_code(:sbtree_bonsai_get_entries_major), do: 113
  defp req_code(:ridbag_get_size),                 do: 114
end
