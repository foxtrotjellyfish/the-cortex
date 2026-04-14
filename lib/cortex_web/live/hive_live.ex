defmodule CortexWeb.HiveLive do
  use CortexWeb, :live_view
  require Logger

  @center_x 400
  @center_y 240
  @radius 170
  @human_y 490

  @domain_colors %{
    general: "#94a3b8"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Cortex.PubSub, "cortex:events")
    end

    stats = if connected?(socket), do: Cortex.Router.stats(), else: %{routed: 0, domains: 0, traces: 0}

    existing_domains =
      if connected?(socket) do
        discover_running_domains()
      else
        %{}
      end

    domain_nodes = build_domain_nodes(existing_domains)

    {:ok,
     assign(socket,
       page_title: "Cortex — The Hive",
       messages: [],
       domains: existing_domains,
       domain_nodes: domain_nodes,
       stats: stats,
       input_value: "",
       pending_count: 0,
       monitored_pids: %{},
       center_x: @center_x,
       center_y: @center_y,
       human_y: @human_y
     ), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-[#0d1117] text-gray-200 overflow-hidden" id="hive-root">
      <%!-- Chat Panel --%>
      <div class="w-[400px] min-w-[360px] flex flex-col bg-[#161b22] border-r border-gray-800">
        <div class="px-5 py-4 border-b border-gray-800">
          <div class="flex items-center gap-3">
            <div class="w-2.5 h-2.5 rounded-full bg-emerald-400 animate-pulse"></div>
            <h1 class="text-lg font-bold tracking-tight text-white">cortex</h1>
            <span class="text-[10px] font-mono text-gray-500 bg-gray-800 px-2 py-0.5 rounded-full">v0.1.0-alpha</span>
          </div>
          <p class="text-[11px] text-gray-500 mt-1.5 font-mono">a nervous system for knowledge work</p>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-4" id="chat-messages" phx-hook="ChatScroll">
          <div :if={@messages == []} class="flex flex-col items-center justify-center h-full opacity-40">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mb-3 text-gray-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z" />
            </svg>
            <p class="text-sm text-gray-500">Type anything. Watch the hive grow.</p>
            <p class="text-xs text-gray-600 mt-1">Try: "I want to plan a trip to Japan but I'm worried about my budget"</p>
          </div>

          <div :for={msg <- @messages} class="animate-fade-in">
            <div :if={msg.role == :user} class="flex justify-end">
              <div class="bg-indigo-600/80 text-white rounded-2xl rounded-br-sm px-4 py-2.5 max-w-[85%] shadow-lg shadow-indigo-500/10">
                <p class="text-sm leading-relaxed">{msg.content}</p>
              </div>
            </div>

            <div :if={msg.role == :domain} class="flex flex-col gap-1">
              <span class="text-[10px] font-mono px-1 flex items-center gap-1.5" style={"color: #{domain_color(msg.domain)}"}>
                <span class="inline-block w-1.5 h-1.5 rounded-full" style={"background: #{domain_color(msg.domain)}"}></span>
                {msg.domain}
                <span :if={msg.duration_ms} class="text-gray-600">{msg.duration_ms}ms</span>
              </span>
              <div class="bg-[#1c2333] rounded-2xl rounded-bl-sm px-4 py-2.5 max-w-[85%] border border-gray-800"
                   style={"border-left: 3px solid #{domain_color(msg.domain)}"}>
                <p class="text-sm leading-relaxed text-gray-300">{msg.content}</p>
              </div>
            </div>

            <div :if={msg.role == :error} class="flex flex-col gap-1">
              <span class="text-[10px] font-mono px-1 text-red-400">
                {msg.domain} error
              </span>
              <div class="bg-red-950/30 rounded-2xl px-4 py-2.5 max-w-[85%] border border-red-900/50">
                <p class="text-xs text-red-400">{msg.content}</p>
              </div>
            </div>
          </div>

          <div :if={@pending_count > 0} class="flex gap-2 items-center px-2 animate-fade-in">
            <span class="flex gap-1">
              <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 0ms"></span>
              <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 150ms"></span>
              <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 300ms"></span>
            </span>
            <span class="text-[11px] text-gray-500 font-mono">
              {if @pending_count == 1, do: "1 domain", else: "#{@pending_count} domains"} processing...
            </span>
          </div>
        </div>

        <form phx-submit="send_message" class="p-4 border-t border-gray-800">
          <div class="flex gap-2">
            <input
              type="text"
              name="message"
              value={@input_value}
              placeholder="Ask anything..."
              class="flex-1 bg-[#0d1117] text-sm text-gray-200 border border-gray-700 rounded-xl px-4 py-2.5 placeholder-gray-600 focus:outline-none focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500/50"
              autocomplete="off"
              autofocus
            />
            <button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white rounded-xl px-4 py-2.5 transition-colors">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8" />
              </svg>
            </button>
          </div>
        </form>
      </div>

      <%!-- Graph Panel --%>
      <div class="flex-1 relative bg-[#0d1117]" id="hive-container" phx-hook="HiveGraph">
        <div class="absolute top-4 left-4 right-4 flex gap-3 z-10">
          <div class="flex items-center gap-2 bg-[#161b22] border border-gray-800 rounded-lg px-3 py-1.5">
            <div class="w-2 h-2 rounded-full bg-emerald-400"></div>
            <span class="font-mono text-[11px] text-gray-400">{map_size(@domains)} domains</span>
          </div>
          <div class="flex items-center gap-2 bg-[#161b22] border border-gray-800 rounded-lg px-3 py-1.5">
            <span class="font-mono text-[11px] text-gray-400">{@stats.routed} signals routed</span>
          </div>
          <div class="flex items-center gap-2 bg-[#161b22] border border-gray-800 rounded-lg px-3 py-1.5">
            <span class="font-mono text-[11px] text-gray-400">{@stats.traces} traces</span>
          </div>
        </div>

        <svg id="hive-svg" viewBox="0 0 800 560" class="w-full h-full" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <filter id="glow">
              <feGaussianBlur stdDeviation="3" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
            <filter id="glow-strong">
              <feGaussianBlur stdDeviation="8" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
          </defs>

          <%!-- Subtle grid --%>
          <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
            <path d="M 40 0 L 0 0 0 40" fill="none" stroke="#1e293b" stroke-width="0.5" />
          </pattern>
          <rect width="100%" height="100%" fill="url(#grid)" />

          <%!-- Edges: human → router --%>
          <line
            x1={@center_x} y1={@human_y}
            x2={@center_x} y2={@center_y}
            stroke="#334155" stroke-width="1" stroke-dasharray="6,4"
          />

          <%!-- Edges: router → domains --%>
          <line
            :for={node <- @domain_nodes}
            x1={@center_x} y1={@center_y}
            x2={node.x} y2={node.y}
            stroke={domain_color(node.id)} stroke-opacity="0.15" stroke-width="1"
            stroke-dasharray="4,4"
          />

          <%!-- Router node (center hexagon) --%>
          <g transform={"translate(#{@center_x}, #{@center_y})"}>
            <polygon
              points="-24,-14 -12,-26 12,-26 24,-14 24,14 12,26 -12,26 -24,14"
              fill="#1e293b" stroke="#475569" stroke-width="1.5"
              filter="url(#glow)"
            />
            <text text-anchor="middle" dy="1" fill="#94a3b8" font-size="9" font-weight="bold" font-family="monospace">
              ROUTER
            </text>
          </g>

          <%!-- Human node (bottom) --%>
          <g transform={"translate(#{@center_x}, #{@human_y})"}>
            <rect x="-32" y="-16" width="64" height="32" rx="16"
                  fill="#1e1b4b" stroke="#4f46e5" stroke-width="1.5" />
            <text text-anchor="middle" dy="5" fill="#a5b4fc" font-size="10" font-weight="bold" font-family="monospace">
              YOU
            </text>
          </g>

          <%!-- Domain nodes --%>
          <g
            :for={node <- @domain_nodes}
            transform={"translate(#{node.x}, #{node.y})"}
            data-domain={node.id}
            class={"domain-node cursor-pointer transition-transform duration-300 #{node_class(node.state)}"}
            phx-click="crash_domain"
            phx-value-domain={node.id}
          >
            <circle
              r={node_radius(node.message_count)}
              fill={domain_color(node.id)} fill-opacity="0.12"
              stroke={domain_color(node.id)} stroke-width="2"
              class="transition-all duration-500"
              filter="url(#glow)"
            />
            <circle r="4" fill={domain_color(node.id)} class="transition-all duration-300" />
            <text
              text-anchor="middle" dy={node_radius(node.message_count) + 16}
              fill={domain_color(node.id)} font-size="11" font-weight="600" font-family="sans-serif"
            >
              {node.label}
            </text>
            <text
              text-anchor="middle" dy={node_radius(node.message_count) + 30}
              fill="#4b5563" font-size="9" font-family="monospace"
            >
              {node.message_count} signals
            </text>
          </g>

          <%!-- Empty state hint --%>
          <text
            :if={@domain_nodes == []}
            x={@center_x} y={@center_y + 80}
            text-anchor="middle" fill="#334155" font-size="13" font-family="sans-serif"
          >
            Send a message to wake the hive
          </text>

          <%!-- Signal animation layer (JS-managed) --%>
          <g id="signal-animations" phx-update="ignore"></g>
        </svg>

        <div class="absolute bottom-4 right-4 text-[10px] text-gray-600 font-mono">
          click a domain to crash it &middot; supervisor restarts automatically
        </div>
      </div>
    </div>
    """
  end

  # --- Events from user ---

  @impl true
  def handle_event("send_message", %{"message" => text}, socket) when byte_size(text) > 0 do
    trimmed = String.trim(text)

    if trimmed != "" do
      Cortex.Router.process_input(trimmed)

      messages =
        socket.assigns.messages ++
          [%{role: :user, content: trimmed, timestamp: DateTime.utc_now()}]

      {:noreply, assign(socket, messages: messages, input_value: "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("crash_domain", %{"domain" => name}, socket) do
    domain_atom = String.to_existing_atom(name)

    case Registry.lookup(Cortex.Domain.Registry, domain_atom) do
      [{pid, _}] ->
        Logger.info("[HiveLive] Crashing domain: #{name}")
        Process.exit(pid, :kill)

        domains = put_in(socket.assigns.domains, [domain_atom, :state], :crashed)
        domain_nodes = build_domain_nodes(domains)

        socket =
          socket
          |> assign(domains: domains, domain_nodes: domain_nodes)
          |> push_event("domain_crashed", %{name: name})

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # --- Events from PubSub ---

  @impl true
  def handle_info({:domain_spawned, %{name: name, pid: pid}}, socket) do
    Process.monitor(pid)

    domains =
      Map.put(socket.assigns.domains, name, %{
        state: :idle,
        message_count: 0,
        spawned_at: DateTime.utc_now(),
        pid: pid
      })

    domain_nodes = build_domain_nodes(domains)
    color = domain_color(name)
    node = Enum.find(domain_nodes, &(&1.id == name))

    socket =
      socket
      |> assign(domains: domains, domain_nodes: domain_nodes, stats: refresh_stats())
      |> push_event("domain_spawned", %{
        name: to_string(name),
        x: node && node.x,
        y: node && node.y,
        color: color
      })

    {:noreply, socket}
  end

  def handle_info({:domain_ready, %{name: name, pid: pid}}, socket) do
    Process.monitor(pid)

    domains =
      if Map.has_key?(socket.assigns.domains, name) do
        socket.assigns.domains
        |> put_in([name, :state], :idle)
        |> put_in([name, :pid], pid)
      else
        Map.put(socket.assigns.domains, name, %{
          state: :idle,
          message_count: 0,
          spawned_at: DateTime.utc_now(),
          pid: pid
        })
      end

    domain_nodes = build_domain_nodes(domains)

    socket =
      socket
      |> assign(domains: domains, domain_nodes: domain_nodes)
      |> push_event("domain_restarted", %{name: to_string(name)})

    {:noreply, socket}
  end

  def handle_info({:signal_routed, %{from: from, to: to}}, socket) do
    from_pos = node_position(socket, from)
    to_pos = node_position(socket, to)

    socket =
      push_event(socket, "signal_routed", %{
        from: to_string(from),
        to: to_string(to),
        fromX: from_pos.x,
        fromY: from_pos.y,
        toX: to_pos.x,
        toY: to_pos.y,
        color: if(from == :human, do: "#6366f1", else: domain_color(to))
      })

    pending = socket.assigns.pending_count + 1
    {:noreply, assign(socket, pending_count: pending)}
  end

  def handle_info({:domain_processing, %{domain: domain}}, socket) do
    domains =
      if Map.has_key?(socket.assigns.domains, domain) do
        put_in(socket.assigns.domains, [domain, :state], :processing)
      else
        socket.assigns.domains
      end

    domain_nodes = build_domain_nodes(domains)

    socket =
      socket
      |> assign(domains: domains, domain_nodes: domain_nodes)
      |> push_event("domain_processing", %{name: to_string(domain)})

    {:noreply, socket}
  end

  def handle_info({:domain_completed, %{domain: domain, output: output} = payload}, socket) do
    domains =
      if Map.has_key?(socket.assigns.domains, domain) do
        socket.assigns.domains
        |> put_in([domain, :state], :idle)
        |> update_in([domain, :message_count], &((&1 || 0) + 1))
      else
        socket.assigns.domains
      end

    domain_nodes = build_domain_nodes(domains)
    duration_ms = Map.get(payload, :duration_ms)

    messages =
      socket.assigns.messages ++
        [
          %{
            role: :domain,
            domain: domain,
            content: output,
            duration_ms: duration_ms,
            timestamp: DateTime.utc_now()
          }
        ]

    pending = max(socket.assigns.pending_count - 1, 0)

    node = Enum.find(domain_nodes, &(&1.id == domain))

    socket =
      socket
      |> assign(
        domains: domains,
        domain_nodes: domain_nodes,
        messages: messages,
        pending_count: pending,
        stats: refresh_stats()
      )
      |> push_event("domain_completed", %{
        name: to_string(domain),
        x: node && node.x,
        y: node && node.y,
        color: domain_color(domain)
      })

    {:noreply, socket}
  end

  def handle_info({:domain_error, %{domain: domain, error: error}}, socket) do
    domains =
      if Map.has_key?(socket.assigns.domains, domain) do
        put_in(socket.assigns.domains, [domain, :state], :idle)
      else
        socket.assigns.domains
      end

    domain_nodes = build_domain_nodes(domains)
    pending = max(socket.assigns.pending_count - 1, 0)

    messages =
      socket.assigns.messages ++
        [%{role: :error, domain: domain, content: error, timestamp: DateTime.utc_now()}]

    {:noreply,
     assign(socket,
       domains: domains,
       domain_nodes: domain_nodes,
       messages: messages,
       pending_count: pending
     )}
  end

  def handle_info({:router_classifying, _}, socket), do: {:noreply, socket}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    domain =
      Enum.find_value(socket.assigns.domains, fn {name, info} ->
        if info[:pid] == pid, do: name
      end)

    if domain do
      Logger.info("[HiveLive] Domain #{domain} crashed — supervisor will restart")

      domains = put_in(socket.assigns.domains, [domain, :state], :crashed)
      domain_nodes = build_domain_nodes(domains)

      socket =
        socket
        |> assign(domains: domains, domain_nodes: domain_nodes)
        |> push_event("domain_crashed", %{name: to_string(domain)})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp build_domain_nodes(domains) do
    domain_names = Map.keys(domains) |> Enum.sort()
    count = max(length(domain_names), 1)

    domain_names
    |> Enum.with_index()
    |> Enum.map(fn {name, i} ->
      angle = 2 * :math.pi() * i / count - :math.pi() / 2

      %{
        id: name,
        type: :domain,
        label: name |> to_string() |> String.replace("_", " ") |> String.capitalize(),
        x: round(@center_x + @radius * :math.cos(angle)),
        y: round(@center_y + @radius * :math.sin(angle)),
        state: domains[name][:state] || :idle,
        message_count: domains[name][:message_count] || 0
      }
    end)
  end

  defp node_position(_socket, :human), do: %{x: @center_x, y: @human_y}
  defp node_position(_socket, :router), do: %{x: @center_x, y: @center_y}

  defp node_position(socket, name) do
    case Enum.find(socket.assigns.domain_nodes, &(&1.id == name)) do
      nil -> %{x: @center_x, y: @center_y}
      node -> %{x: node.x, y: node.y}
    end
  end

  defp domain_color(name) when is_atom(name) do
    Map.get(@domain_colors, name, generate_color(name))
  end

  defp generate_color(name) do
    hue = :erlang.phash2(name, 360)
    "hsl(#{hue}, 70%, 65%)"
  end

  defp node_radius(message_count) do
    16 + min(message_count * 2, 14)
  end

  defp node_class(:processing), do: "processing"
  defp node_class(:crashed), do: "crashed"
  defp node_class(_), do: ""

  defp refresh_stats do
    Cortex.Router.stats()
  catch
    :exit, _ -> %{routed: 0, domains: 0, traces: 0}
  end

  defp discover_running_domains do
    Registry.select(Cortex.Domain.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      Process.monitor(pid)
      msg_count = get_domain_message_count(name)

      {name, %{
        state: :idle,
        message_count: msg_count,
        spawned_at: nil,
        pid: pid
      }}
    end)
    |> Map.new()
  end

  defp get_domain_message_count(name) do
    case Cortex.Domains.Dynamic.get_state(name) do
      %{message_count: count} -> count
      _ -> 0
    end
  end
end
