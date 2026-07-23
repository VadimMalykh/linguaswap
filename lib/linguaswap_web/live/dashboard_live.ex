defmodule LinguaswapWeb.DashboardLive do
  use LinguaswapWeb, :live_view
  alias Linguaswap.Vocabulary

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    stats = Vocabulary.get_user_stats(user.id)

    {:ok, assign(socket, stats: stats)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-8">Your Progress</h1>
      
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
        <div class="bg-white p-6 rounded-lg shadow-md">
          <div class="text-4xl font-bold text-emerald-600"><%= @stats.total_words %></div>
          <div class="text-gray-600 mt-2">Total Words</div>
        </div>
        
        <div class="bg-white p-6 rounded-lg shadow-md">
          <div class="text-4xl font-bold text-blue-600"><%= @stats.known_words %></div>
          <div class="text-gray-600 mt-2">Known Words</div>
        </div>
        
        <div class="bg-white p-6 rounded-lg shadow-md">
          <div class="text-4xl font-bold text-amber-600"><%= @stats.learning_words %></div>
          <div class="text-gray-600 mt-2">Learning</div>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="bg-white p-6 rounded-lg shadow-md">
          <h2 class="text-xl font-semibold mb-4">Statistics</h2>
          <div class="space-y-3">
            <div class="flex justify-between">
              <span class="text-gray-600">Total Reveals</span>
              <span class="font-medium"><%= @stats.total_reveals %></span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-600">Words Replaced</span>
              <span class="font-medium"><%= @stats.total_replacements %></span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-600">New Words</span>
              <span class="font-medium"><%= @stats.new_words %></span>
            </div>
          </div>
        </div>

        <div class="bg-white p-6 rounded-lg shadow-md">
          <h2 class="text-xl font-semibold mb-4">Quick Actions</h2>
          <div class="space-y-3">
            <.link navigate="/email/settings" class="block w-full text-center bg-emerald-500 text-white py-2 px-4 rounded-lg hover:bg-emerald-600 transition">
              Settings
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
