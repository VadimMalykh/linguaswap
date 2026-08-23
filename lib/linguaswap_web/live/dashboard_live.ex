defmodule LinguaswapWeb.DashboardLive do
  use LinguaswapWeb, :live_view
  alias Linguaswap.Vocabulary

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    stats = Vocabulary.get_user_stats(user.id)

    language_pair = Vocabulary.language_pair_for_target(user.target_language)
    budget = Vocabulary.word_budget(user.settings)
    pool = Vocabulary.pool_stats(user.id, language_pair, budget)

    {:ok, assign(socket, stats: stats, pool: pool, language_pair: language_pair)}
  end

  defp pool_percentage(%{active: active, budget: budget}) when budget > 0 do
    min(round(active / budget * 100), 100)
  end

  defp pool_percentage(_pool), do: 0

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto p-6">
        <h1 class="text-3xl font-bold mb-8">Your Progress</h1>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-6 mb-8">
          <div class="bg-white p-6 rounded-lg shadow-md">
            <div class="text-4xl font-bold text-emerald-600">{@stats.total_words}</div>
            <div class="text-gray-600 mt-2">Total Words</div>
          </div>

          <div class="bg-white p-6 rounded-lg shadow-md">
            <div class="text-4xl font-bold text-red-600">{@stats.hard_words}</div>
            <div class="text-gray-600 mt-2">Hard</div>
          </div>

          <div class="bg-white p-6 rounded-lg shadow-md">
            <div class="text-4xl font-bold text-amber-600">{@stats.simple_words}</div>
            <div class="text-gray-600 mt-2">Simple</div>
          </div>

          <div class="bg-white p-6 rounded-lg shadow-md">
            <div class="text-4xl font-bold text-emerald-500">{@stats.trivial_words}</div>
            <div class="text-gray-600 mt-2">Easy</div>
          </div>
        </div>

        <div class="bg-white p-6 rounded-lg shadow-md mb-8">
          <div class="flex items-baseline justify-between mb-4">
            <h2 class="text-xl font-semibold">Learning Pool</h2>
            <span class="text-sm text-gray-500">{@language_pair}</span>
          </div>

          <div class="flex items-baseline gap-2 mb-3">
            <span class="text-3xl font-bold text-emerald-600">{@pool.active}</span>
            <span class="text-gray-500">of {@pool.budget} active words</span>
          </div>

          <div class="h-2 w-full bg-gray-100 rounded-full overflow-hidden mb-4">
            <div
              class="h-full bg-emerald-500 rounded-full transition-all duration-500"
              style={"width: #{pool_percentage(@pool)}%"}
            >
            </div>
          </div>

          <div class="flex justify-between text-sm text-gray-600">
            <span>{@pool.graduated} graduated</span>
            <span>{@pool.remaining} waiting to be introduced</span>
          </div>

          <p class="text-sm text-gray-500 mt-4">
            New words are introduced in frequency order as you master the ones you have.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-white p-6 rounded-lg shadow-md">
            <h2 class="text-xl font-semibold mb-4">Statistics</h2>
            <div class="space-y-3">
              <div class="flex justify-between">
                <span class="text-gray-600">Total Reveals</span>
                <span class="font-medium">{@stats.total_reveals}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-gray-600">Words Replaced</span>
                <span class="font-medium">{@stats.total_replacements}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-gray-600">Trivial (mastered)</span>
                <span class="font-medium">{@stats.trivial_words}</span>
              </div>
            </div>
          </div>

          <div class="bg-white p-6 rounded-lg shadow-md">
            <h2 class="text-xl font-semibold mb-4">Quick Actions</h2>
            <div class="space-y-3">
              <.link
                navigate="/email/settings"
                class="block w-full text-center bg-emerald-500 text-white py-2 px-4 rounded-lg hover:bg-emerald-600 transition"
              >
                Settings
              </.link>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
