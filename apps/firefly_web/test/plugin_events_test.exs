defmodule FireflyWeb.PluginEventsTest do
  use FireflyWeb.ConnCase

  @moduletag :capture_log

  import Ecto.Query
  import FireflyPlugins.PluginHelpers

  alias Firefly.{Accounts, Discussion, Groups, Plugins, Repo}
  alias Firefly.Discussion.{Polls, Solved}
  alias Firefly.Moderation.{Flags, Review}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Poll, Post, Thread}
  alias Firefly.Notifications.Notification
  alias Firefly.Plugin.Runner
  alias Firefly.Plugins.{EventWorker, Events, Fields, HTTP, Health, Jobs, Storage}

  setup do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture("Public")
    thread = thread_fixture(category, member, %{title: "Hello", body: "first"})
    %{admin: admin, member: member, category: category, thread: thread}
  end

  defp queued, do: Enum.sort_by(all_enqueued(worker: EventWorker), & &1.id)
  defp queued_events, do: Enum.map(queued(), & &1.args["event"])

  # A plugin whose `go` export runs `body` (JS) with `args`, as `call/2` does.
  defp actor(admin, manifest, body) do
    install_plugin!(
      admin,
      Map.merge(%{"id" => "actor", "name" => "Actor", "exports" => ["go"]}, manifest),
      %{"index.js" => "exports.go = (args) => { #{body} }"},
      enable: true
    )
  end

  defp call(args \\ nil),
    do: Runner.invoke(Plugins.get_active("actor"), "call_export", ["go", args])

  describe "events" do
    defp listener(admin, events, extra \\ %{}) do
      install_plugin!(
        admin,
        Map.merge(
          %{
            "id" => "listener",
            "name" => "Listener",
            "hooks" => ["handle_event"],
            "events" => events,
            "permissions" => ["read"]
          },
          extra
        ),
        %{
          "index.js" => """
          exports.handle_event = ({event, data}) => {
            const seen = firefly.call('kv.get', {key: 'seen'}) || [];
            firefly.call('kv.set', {key: 'seen', value: seen.concat([[event, data]])});
          };
          """
        },
        enable: true
      )
    end

    defp seen, do: Storage.get("listener", "seen") || []

    test "are queued with the content's transaction and delivered", %{
      admin: admin,
      thread: thread,
      member: member
    } do
      listener(admin, ["post_created"])
      {:ok, post} = Discussion.create_post(thread, member, %{body: "a reply"})

      assert ["post_created"] = queued_events()
      assert %{success: 1} = Oban.drain_queue(queue: :plugins)
      assert queued() == []

      assert [
               [
                 "post_created",
                 %{
                   "post" => %{"id" => id, "body" => "a reply", "author" => author},
                   "thread" => %{"title" => "Hello"}
                 }
               ]
             ] =
               seen()

      assert id == post.id
      assert author == member.username
    end

    test "every kind is emitted", %{
      admin: admin,
      thread: thread,
      member: member,
      category: category
    } do
      listener(admin, Events.names(), %{"permissions" => ["read", "flag"]})
      other = user_fixture()

      thread_fixture(category, member, %{title: "Another"})
      {:ok, reply} = Discussion.create_post(thread, other, %{body: "reply"})
      {:ok, reply} = Discussion.update_post(reply, other, %{body: "edited"})
      :ok = Discussion.like_post(reply, member)
      {:ok, _flag} = Flags.flag_post(reply, member, %{reason: "spam"})
      {:ok, _} = Discussion.delete_post(reply, other)

      {:ok, _} =
        Accounts.register_user(%{
          username: "newbie",
          email: "newbie@example.com",
          password: "password1"
        })

      {:ok, qa} = Discussion.create_category(%{title: "Q&A", allow_accepted_answers: true})
      question = thread_fixture(qa, member, %{title: "How?"})
      {:ok, answer} = Discussion.create_post(question, other, %{body: "Like so"})
      {:ok, _} = Solved.accept(question, answer, member)

      poll_attrs = Polls.attrs(%{"options_text" => "Yes\nNo"}, 0)
      {:ok, poll_post} = Discussion.create_post(thread, member, %{body: "vote", poll: poll_attrs})
      {:ok, _} = Polls.close(Repo.get_by!(Poll, post_id: poll_post.id), member)

      {:ok, _} = Discussion.update_category(qa, %{title: "Questions"}, admin)
      {:ok, doomed} = Discussion.create_category(%{title: "Doomed"})
      {:ok, _} = Discussion.delete_category(doomed, admin)

      Firefly.SiteSettings.update(%{"approve_new_user_posts" => "5"}, admin)
      newcomer = user_fixture()
      {:ok, waiting} = Discussion.create_post(thread, newcomer, %{body: "first"})
      {:ok, refused} = Discussion.create_post(thread, newcomer, %{body: "second"})
      {:ok, _} = Review.approve(waiting, admin)
      {:ok, _} = Review.reject(refused, admin, "Off-topic")

      {:ok, channel} = Firefly.Chat.create_channel(%{"name" => "Lobby"}, admin)
      {:ok, chat} = Firefly.Chat.send_message(channel, member, %{"body" => "hi"})
      {:ok, _} = Firefly.Chat.edit_message(chat, member, %{"body" => "hi!"})
      {:ok, _} = Firefly.Chat.delete_message(chat, member)

      # Direct messages never reach plugins.
      created = Enum.count(queued_events(), &(&1 == "chat_message_created"))
      {:ok, dm} = Firefly.Chat.direct_channel(admin, [member.username])
      {:ok, _} = Firefly.Chat.send_message(dm, admin, %{"body" => "private"})
      assert Enum.count(queued_events(), &(&1 == "chat_message_created")) == created

      assert Enum.sort(Enum.uniq(queued_events())) == Enum.sort(Events.names())
    end

    test "nothing from private categories", %{admin: admin} do
      listener(admin, ["thread_created", "post_created"])
      {:ok, role} = Groups.create_role("staff")
      {:ok, private} = Discussion.create_category(%{title: "Staff", role_ids: [role.id]})
      secret = thread_fixture(private, admin, %{title: "Secret"})
      {:ok, _} = Discussion.create_post(secret, admin, %{body: "psst"})

      assert queued() == []
    end

    test "flag_raised needs the flag permission" do
      assert {:error, message} =
               Firefly.Plugin.Manifest.parse(
                 %{
                   "id" => "flags",
                   "name" => "F",
                   "version" => "1.0.0",
                   "firefly" => "~> 1.0",
                   "hooks" => ["handle_event"],
                   "events" => ["flag_raised"],
                   "permissions" => ["read"]
                 },
                 "upload"
               )

      assert message =~ "flag_raised event needs the flag permission"
    end

    test "failed deliveries are retried with backoff, then dropped", %{
      admin: admin,
      thread: thread,
      member: member
    } do
      install_plugin!(
        admin,
        %{
          "id" => "flaky",
          "name" => "F",
          "hooks" => ["handle_event"],
          "events" => ["post_created"],
          "permissions" => ["read"]
        },
        %{"index.js" => "exports.handle_event = () => { throw new Error('down') }"},
        enable: true
      )

      {:ok, _} = Discussion.create_post(thread, member, %{body: "x"})
      [%{args: args}] = queued()

      # Retried after 30 seconds, 2, 8 and 32 minutes.
      assert Enum.map(1..4, &EventWorker.backoff(%Oban.Job{attempt: &1})) == [30, 120, 480, 1920]

      for attempt <- 1..4 do
        assert {:error, "js_error: down" <> _} = perform_job(EventWorker, args, attempt: attempt)
      end

      assert Health.errors("flaky") |> Enum.filter(&(&1.kind == "gave_up")) == []
      assert {:error, _} = perform_job(EventWorker, args, attempt: 5)

      assert [%{kind: "gave_up", message: "Dropped post_created after 5 attempts" <> _} | _] =
               Health.errors("flaky")
    end

    test "a plugin isn't told about its own bot's posts", %{
      admin: admin,
      thread: thread,
      member: member
    } do
      install_plugin!(
        admin,
        %{
          "id" => "echo",
          "name" => "Echo",
          "hooks" => ["handle_event"],
          "events" => ["post_created"],
          "permissions" => ["read", "post"]
        },
        %{
          "index.js" =>
            "exports.handle_event = ({data}) => firefly.call('posts.reply', {thread_id: data.thread.id, body: 'Echo: ' + data.post.body})"
        },
        enable: true
      )

      {:ok, _} = Discussion.create_post(thread, member, %{body: "hi"})
      assert %{success: 1} = Oban.drain_queue(queue: :plugins)
      assert queued() == []

      bot = Repo.get_by!(User, plugin_bot: "echo")
      assert [%Post{body: "Echo: hi"}] = Repo.all(from(p in Post, where: p.user_id == ^bot.id))
    end

    test "events for an inactive plugin are dropped", %{
      admin: admin,
      thread: thread,
      member: member
    } do
      listener(admin, ["post_created"])
      {:ok, _} = Discussion.create_post(thread, member, %{body: "x"})
      {:ok, _} = Plugins.disable("listener", admin)

      assert %{cancelled: 1} = Oban.drain_queue(queue: :plugins)
      assert queued() == []
    end
  end

  describe "actions" do
    test "replying goes through the posting checks, as the plugin's bot", %{
      admin: admin,
      thread: thread
    } do
      actor(
        admin,
        %{"permissions" => ["post"]},
        "return firefly.call('posts.reply', {thread_id: args, body: 'Bot here'})"
      )

      bot = Repo.get_by!(User, plugin_bot: "actor")
      assert bot.username == "actor-bot"

      assert {:ok, %{"id" => id}} = call(thread.id)
      assert %Post{user_id: user_id, body: "Bot here"} = Repo.get!(Post, id)
      assert user_id == bot.id

      {:ok, _} = Discussion.close_thread(thread, true, admin)
      assert {:error, {:js_error, "This thread is closed to new replies." <> _}} = call(thread.id)
    end

    test "permissions are denied by default", %{admin: admin, thread: thread} do
      actor(admin, %{}, "return firefly.call('posts.reply', {thread_id: args, body: 'x'})")
      assert {:error, {:js_error, message}} = call(thread.id)
      assert message =~ ~s(posts.reply needs the "post" permission)
    end

    test "private threads are out of reach", %{admin: admin} do
      {:ok, role} = Groups.create_role("staff")
      {:ok, private} = Discussion.create_category(%{title: "Staff", role_ids: [role.id]})
      secret = thread_fixture(private, admin)

      actor(admin, %{"permissions" => ["post", "moderate", "tags"]}, """
      const results = [];
      for (const [name, extra] of [['posts.reply', {body: 'x'}], ['threads.close', {closed: true}], ['tags.add', {tag: 'x'}]]) {
        try { firefly.call(name, Object.assign({thread_id: args}, extra)); results.push('done') }
        catch (e) { results.push(e.message) }
      }
      return results;
      """)

      assert {:ok, ["not found", "not found", "not found"]} = call(secret.id)
    end

    test "tags, closing and pinning, as the bot and logged", %{admin: admin, thread: thread} do
      actor(admin, %{"permissions" => ["tags", "moderate"]}, """
      firefly.call('tags.add', {thread_id: args, tag: 'triaged'});
      firefly.call('tags.add', {thread_id: args, tag: 'bug'});
      firefly.call('tags.remove', {thread_id: args, tag: 'triaged'});
      firefly.call('threads.close', {thread_id: args, closed: true});
      return firefly.call('threads.pin', {thread_id: args, pinned: true});
      """)

      assert {:ok, nil} = call(thread.id)
      thread = Thread |> Repo.get!(thread.id) |> Repo.preload(:tags)
      assert Enum.map(thread.tags, & &1.name) == ["bug"]
      assert thread.closed_at && thread.pinned_at

      bot = Repo.get_by!(User, plugin_bot: "actor")

      # Tag changes on someone else's thread are logged as edits.
      assert ["thread.edit", "thread.edit", "thread.edit", "thread.close", "thread.pin"] =
               Repo.all(
                 from(a in Firefly.Moderation.StaffAction,
                   where: a.actor_id == ^bot.id,
                   order_by: a.id,
                   select: a.action
                 )
               )
    end

    test "flagging and notifying", %{admin: admin, thread: thread, member: member} do
      [post] = Repo.preload(thread, :posts).posts

      actor(admin, %{"permissions" => ["flag", "notify"]}, """
      firefly.call('posts.flag', {post_id: args.post, reason: 'spam', note: 'looks automated'});
      firefly.call('notifications.send', {user_id: args.user, subject: 'Hi', body: 'Welcome!', path: '/tags'});
      try { firefly.call('notifications.send', {user_id: args.user, subject: 'x', body: 'x', path: 'https://evil.example'}) }
      catch (e) { return e.message }
      """)

      assert {:ok, "path must be a path on this site" <> _} =
               call(%{"post" => post.id, "user" => member.id})

      assert Flags.flagged?(post, Repo.get_by!(User, plugin_bot: "actor"))

      assert [%Notification{kind: "plugin", subject: "Actor: Hi", body: "Welcome!", url: url}] =
               Repo.all(from(n in Notification, where: n.user_id == ^member.id))

      assert String.ends_with?(url, "/tags")
    end
  end

  describe "storage" do
    test "keeps each plugin's keys to itself, within quota", %{admin: admin} do
      actor(admin, %{}, """
      firefly.call('kv.set', {key: 'a:1', value: {n: 1}});
      firefly.call('kv.set', {key: 'a:2', value: [1, 2]});
      firefly.call('kv.set', {key: 'b', value: 'x'});
      firefly.call('kv.delete', {key: 'b'});
      return [firefly.call('kv.get', {key: 'a:1'}), firefly.call('kv.list', {prefix: 'a:'})];
      """)

      assert {:ok, [%{"n" => 1}, ["a:1", "a:2"]]} = call()
      assert Storage.get("other", "a:1") == nil

      Application.put_env(:firefly, Storage, max_keys: 2)

      try do
        assert {:error, "storage quota exceeded: too many keys"} = Storage.put("actor", "c", 1)
        assert :ok = Storage.put("actor", "a:1", 2)
      after
        Application.delete_env(:firefly, Storage)
      end
    end

    test "user_id picks a member's own namespace", %{admin: admin, member: member} do
      other = user_fixture()

      actor(admin, %{}, """
      const u = args.user, o = args.other;
      firefly.call('kv.set', {key: 'k', value: 'global'});
      firefly.call('kv.set', {key: 'k', value: 'mine', user_id: u});
      firefly.call('kv.set', {key: 'k2', value: 2, user_id: u});
      firefly.call('kv.set', {key: 'k', value: 'theirs', user_id: o});
      firefly.call('kv.delete', {key: 'k2', user_id: o});
      const errors = [];
      for (const id of [999999999, 'x']) {
        try { firefly.call('kv.get', {key: 'k', user_id: id}) } catch (e) { errors.push(e.message) }
      }
      return [
        firefly.call('kv.get', {key: 'k'}),
        firefly.call('kv.get', {key: 'k', user_id: u}),
        firefly.call('kv.get', {key: 'k', user_id: o}),
        firefly.call('kv.list', {}),
        firefly.call('kv.list', {user_id: u}),
        errors
      ];
      """)

      assert {:ok,
              [
                "global",
                "mine",
                "theirs",
                ["k"],
                ["k", "k2"],
                ["user not found", "user_id must be a user's id"]
              ]} = call(%{"user" => member.id, "other" => other.id})

      assert Storage.get({"actor", member.id}, "k") == "mine"
      assert Storage.usage("actor") == %{keys: 1, bytes: 8}
    end

    test "each member's store has its own quota", %{member: member} do
      other = user_fixture()
      Application.put_env(:firefly, Storage, user_max_keys: 2, user_max_bytes: 10)

      try do
        assert :ok = Storage.put({"p", member.id}, "a", 1)
        assert :ok = Storage.put({"p", member.id}, "b", 1)

        assert {:error, "storage quota exceeded: too many keys"} =
                 Storage.put({"p", member.id}, "c", 1)

        assert {:error, "storage quota exceeded: too much data"} =
                 Storage.put({"p", member.id}, "a", "0123456789")

        # Other members, other plugins and the global store aren't affected.
        assert :ok = Storage.put({"p", other.id}, "c", 1)
        assert :ok = Storage.put({"q", member.id}, "c", 1)
        assert :ok = Storage.put("p", "c", "a long global value")
      after
        Application.delete_env(:firefly, Storage)
      end
    end
  end

  describe "custom fields" do
    test "are namespaced, declared, and public ones show in the API", %{
      admin: admin,
      thread: thread
    } do
      [post] = Repo.preload(thread, :posts).posts

      actor(
        admin,
        %{
          "permissions" => ["fields"],
          "fields" => [
            %{"type" => "post", "key" => "score", "public" => true},
            %{"type" => "post", "key" => "secret"}
          ]
        },
        """
        firefly.call('fields.set', {type: 'post', id: args, key: 'score', value: 42});
        firefly.call('fields.set', {type: 'post', id: args, key: 'secret', value: 'hush'});
        try { firefly.call('fields.set', {type: 'post', id: args, key: 'other', value: 1}) } catch (e) {}
        return firefly.call('fields.get', {type: 'post', id: args});
        """
      )

      assert {:ok, %{"score" => 42, "secret" => "hush"}} = call(post.id)
      assert Fields.public("post", [post.id]) == %{post.id => %{"actor" => %{"score" => 42}}}

      assert %{plugin_fields: %{"actor" => %{"score" => 42}}} =
               FireflyWeb.Api.V1.PostJSON.data(Repo.get!(Post, post.id))
    end
  end

  describe "http" do
    test "only allowlisted hosts, only public addresses" do
      assert {:error, :host_not_allowed, "host evil.example isn't in the plugin's http_hosts"} =
               HTTP.fetch(["api.example.com"], %{"url" => "https://evil.example/x"})

      assert {:error, :invalid, "only http and https URLs can be fetched"} =
               HTTP.fetch(["api.example.com"], %{"url" => "file:///etc/passwd"})

      assert {:error, :private_address, "localhost resolves to a private address"} =
               HTTP.fetch(["localhost"], %{"url" => "#{FireflyWeb.Endpoint.url()}/"})

      assert HTTP.allowed?("a.b.example.com", ["*.example.com"])
      refute HTTP.allowed?("example.com", ["*.example.com"])
      refute HTTP.allowed?("evilexample.com", ["*.example.com"])

      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {169, 254, 169, 254},
            {100, 64, 0, 1},
            {0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ],
          do: refute(HTTP.public?(ip), inspect(ip))

      assert HTTP.public?({93, 184, 216, 34})
      assert HTTP.public?({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
    end

    test "fetches, without following redirects" do
      Application.put_env(:firefly, HTTP, allow_private: true)

      try do
        assert {:ok, %{status: 200, body: body}} =
                 HTTP.fetch(["localhost"], %{"url" => "#{FireflyWeb.Endpoint.url()}/"})

        assert body =~ "<html"

        assert {:ok, %{status: 302}} =
                 HTTP.fetch(["localhost"], %{"url" => "#{FireflyWeb.Endpoint.url()}/drafts"})
      after
        Application.delete_env(:firefly, HTTP)
      end
    end

    test "needs the permission and declared hosts" do
      assert {:error, message} =
               Firefly.Plugin.Manifest.parse(
                 %{
                   "id" => "web",
                   "name" => "W",
                   "version" => "1.0.0",
                   "firefly" => "~> 1.0",
                   "permissions" => ["http"]
                 },
                 "upload"
               )

      assert message =~ ~s(the http permission and "http_hosts" go together)
    end
  end

  describe "scheduled jobs" do
    test "schedules parse, and the next run time follows them" do
      at = ~U[2026-11-02 10:17:30Z]
      {:ok, every} = Jobs.parse(%{"every" => 3600})
      assert Jobs.next(every, at) == ~U[2026-11-02 11:17:30Z]

      {:ok, nightly} = Jobs.parse(%{"cron" => "30 2 * * *"})
      assert Jobs.next(nightly, at) == ~U[2026-11-03 02:30:00Z]

      {:ok, quarter} = Jobs.parse(%{"cron" => "*/15 * * * *"})
      assert Jobs.next(quarter, at) == ~U[2026-11-02 10:30:00Z]

      # Mondays at 9 (2 November 2026 is a Monday).
      {:ok, monday} = Jobs.parse(%{"cron" => "0 9 * * 1"})
      assert Jobs.next(monday, at) == ~U[2026-11-09 09:00:00Z]

      {:ok, first} = Jobs.parse(%{"cron" => "0 0 1 1-6/2 *"})
      assert Jobs.next(first, at) == ~U[2027-01-01 00:00:00Z]

      for bad <- [
            %{"every" => 5},
            %{"cron" => "61 * * * *"},
            %{"cron" => "* * *"},
            %{"cron" => "x * * * *"},
            %{}
          ],
          do: assert(Jobs.parse(bad) == :error, inspect(bad))
    end

    test "due jobs run once and are rescheduled", %{admin: admin} do
      install_plugin!(
        admin,
        %{
          "id" => "ticker",
          "name" => "T",
          "hooks" => ["run_job"],
          "jobs" => [%{"name" => "tick", "every" => 60}]
        },
        %{
          "index.js" =>
            "exports.run_job = ({job}) => firefly.call('kv.set', {key: job, value: (firefly.call('kv.get', {key: job}) || 0) + 1})"
        },
        enable: true
      )

      now = DateTime.utc_now()
      # The first run only schedules it.
      assert Jobs.run_due(now) == 0
      assert Jobs.run_due(DateTime.add(now, 61)) == 1
      assert Jobs.run_due(DateTime.add(now, 62)) == 0
      assert Storage.get("ticker", "tick") == 1
    end
  end

  test "uninstalling deletes the plugin's data", %{admin: admin, thread: thread, member: member} do
    install_plugin!(
      admin,
      %{
        "id" => "keeper",
        "name" => "K",
        "hooks" => ["handle_event"],
        "events" => ["post_created"],
        "permissions" => ["read", "fields"],
        "fields" => [%{"type" => "thread", "key" => "x"}]
      },
      %{"index.js" => "exports.handle_event = () => null"},
      enable: true
    )

    :ok = Storage.put("keeper", "k", 1)
    :ok = Storage.put({"keeper", member.id}, "k", 1)
    :ok = Fields.put(Plugins.get_active("keeper"), "thread", thread.id, "x", 1)
    {:ok, _} = Discussion.create_post(thread, member, %{body: "x"})

    :ok = Plugins.uninstall("keeper", admin)

    assert Storage.usage("keeper") == %{keys: 0, bytes: 0}
    assert Storage.usage({"keeper", member.id}) == %{keys: 0, bytes: 0}
    assert Fields.get("keeper", "thread", thread.id) == %{}
    assert queued() == []
    assert Repo.get_by(User, plugin_bot: "keeper")
  end

  describe "a member's plugin data" do
    setup %{admin: admin} do
      install_plugin!(
        admin,
        %{
          "id" => "keeper",
          "name" => "K",
          "permissions" => ["fields"],
          "fields" => [%{"type" => "user", "key" => "badge"}, %{"type" => "post", "key" => "x"}]
        },
        %{"index.js" => ""},
        enable: true
      )

      %{plugin: Plugins.get_active("keeper")}
    end

    test "is in their account export, by plugin", %{plugin: plugin, member: member} do
      other = user_fixture()
      :ok = Storage.put({"keeper", member.id}, "seen", [1, 2])
      :ok = Storage.put({"other", member.id}, "theme", "dark")
      :ok = Storage.put({"keeper", other.id}, "seen", [3])
      :ok = Storage.put("keeper", "global", true)
      :ok = Fields.put(plugin, "user", member.id, "badge", "gold")
      :ok = Fields.put(plugin, "user", other.id, "badge", "tin")

      export = Firefly.Accounts.AccountExport.build(member)

      assert export.plugin_storage == %{
               "keeper" => %{"seen" => [1, 2]},
               "other" => %{"theme" => "dark"}
             }

      assert export.plugin_fields == %{"keeper" => %{"badge" => "gold"}}
    end

    test "is deleted with their account; fields on their posts stay", %{
      admin: admin,
      plugin: plugin,
      member: member,
      thread: thread
    } do
      other = user_fixture()
      [post] = Repo.preload(thread, :posts).posts
      :ok = Storage.put({"keeper", member.id}, "seen", 1)
      :ok = Storage.put({"keeper", other.id}, "seen", 1)
      :ok = Fields.put(plugin, "user", member.id, "badge", "gold")
      :ok = Fields.put(plugin, "user", other.id, "badge", "tin")
      :ok = Fields.put(plugin, "post", post.id, "x", 1)

      {:ok, _} = Firefly.Accounts.AccountDeletion.delete_account(member, member.username)

      assert Storage.usage({"keeper", member.id}) == %{keys: 0, bytes: 0}
      assert Storage.get({"keeper", other.id}, "seen") == 1
      assert Fields.get("keeper", "user", member.id) == %{}
      assert Fields.get("keeper", "user", other.id) == %{"badge" => "tin"}
      assert Fields.get("keeper", "post", post.id) == %{"x" => 1}

      # The placeholder account is no one to keep data for.
      actor(admin, %{}, """
      try { firefly.call('kv.set', {key: 'k', value: 1, user_id: args}) } catch (e) { return e.message }
      """)

      assert {:ok, "user not found"} = call(member.id)
    end
  end
end
