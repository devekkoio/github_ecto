defmodule GitHub.Ecto do
  alias GitHub.Ecto.Search
  alias GitHub.Ecto.Request
  alias GitHub.Client

  ## Boilerplate

  @behaviour Ecto.Adapter

  defmacro __before_compile__(_opts), do: :ok

  def application do
    :github_ecto
  end

  def child_spec(_repo, opts) do
    token = Keyword.get(opts, :token)
    Supervisor.Spec.worker(Client, [token])
  end

  def stop(_, _, _), do: :ok

  def loaders(primitive, _type), do: [primitive]

  def dumpers(primitive, _type), do: [primitive]

  def embed_id(_), do: raise "Not supported by adapter"

  def prepare(operation, query), do: {:nocache, {operation, query}}

  def autogenerate(_), do: ""

  ## Reads

  def execute(_repo, %{fields: fields} = _meta, {:nocache, {:all, query}}, [] = _params, preprocess, opts) do
    client = opts[:client] || Client
    path = Search.build(query)

    items =
      client.get!(path)
      |> Map.fetch!("items")
      |> Enum.map(fn item -> process_item(item, fields, preprocess) end)

    {0, items}
  end

  defp process_item(item, [{:&, [], [0, nil, _]}], _preprocess) do
    [item]
  end
  defp process_item(item, [{:&, [], [0, field_names, _]}], preprocess) do
    field_names = field_names -- [:repo]

    fields = [{:&, [], [0, field_names, nil]}]
    values = Enum.map(field_names, fn field -> Map.fetch!(item, Atom.to_string(field)) end)
    [preprocess.(hd(fields), values, nil) |> process_assocs(item) ]
  end
  defp process_item(item, exprs, preprocess) do
    Enum.map(exprs, fn {{:., [], [{:&, [], [0]}, field]}, _, []} ->
      preprocess.(field, Map.fetch!(item, Atom.to_string(field)), nil)
    end)
  end

  defp process_assocs(%{__struct__: struct} = schema, item) do
    Enum.map(struct.__schema__(:associations), fn assoc ->
      attributes = item[Atom.to_string(assoc)]

      if attributes do
        queryable = struct.__schema__(:association, assoc).queryable
        fields = queryable.__schema__(:fields) |> Enum.map(&Atom.to_string/1)

        attributes =
          Enum.into(attributes, %{}, fn {key, value} ->
            if key in fields do
              {String.to_atom(key), value}
            else
              {nil, nil}
            end
          end)

        {assoc, struct(queryable, attributes)}
      else
        {assoc, nil}
      end
    end)
    |> Enum.reduce(schema, fn({assoc, assoc_schema}, schema) ->
      Map.put(schema, assoc, assoc_schema)
    end)
  end

  ## Writes

  def insert(_repo, %{schema: schema} = _meta, params, _autogen, _opts) do
    result = Request.build(schema, params) |> Client.post!
    do_insert(schema, result)
  end

  defp do_insert(GitHub.Issue, %{"url" => url, "number" => number, "html_url" => html_url, "user" => user, "assignee" => assignee}) do
    {:ok, %{id: url, number: number, url: html_url, user: user, assignee: assignee}}
  end
  defp do_insert(GitHub.Repository, %{"url" => url, "private" => private, "owner" => owner}) do
    {:ok, %{id: url, private: private, owner: owner}}
  end

  def insert_all(_, _, _, _, _, _), do: raise "Not supported by adapter"

  def delete(_, _, _, _), do: raise "Not supported by adapter"

  def update(_repo, %{schema: schema} = _meta, params, filter, _autogen, _opts) do
    id = Keyword.fetch!(filter, :id)

    Request.build_patch(schema, id, params) |> Client.patch!
    {:ok, %{}}
  end
end

defmodule GitHub.Ecto.Request do
  def build(GitHub.Issue, params) do
    repo = Keyword.fetch!(params, :repo)
    title = Keyword.fetch!(params, :title)
    body = Keyword.fetch!(params, :body)
    assignee = get_in(params, [:assignee, :login])

    path = "/repos/#{repo}/issues"
    json = Poison.encode!(%{title: title, body: body, assignee: assignee})

    {path, json}
  end
  def build(GitHub.Repository, params) do
    path = "/user/repos"
    json = Poison.encode!(Enum.into(params, %{}))

    {path, json}
  end

  def build_patch(GitHub.Issue, id, params) do
    "https://api.github.com" <> path = id
    json = Enum.into(params, %{}) |> Poison.encode!

    {path, json}
  end
end
