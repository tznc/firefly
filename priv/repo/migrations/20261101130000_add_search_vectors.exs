defmodule FirestormWeb.Repo.Migrations.AddSearchVectors do
  use Ecto.Migration

  # Full-text search columns, with GIN indexes for `@@` queries:
  #
  #   * forums_threads.search_vector: the title (generated column), for
  #     title-only searches
  #   * forums_posts.search_vector: the body, plus the thread title (weighted
  #     higher) for a thread's first post, so a search for words spread over
  #     a title and its post finds the post. It spans two tables, so triggers
  #     keep it up to date instead of a generated column.
  def up do
    execute """
    ALTER TABLE forums_threads ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (setweight(to_tsvector('english', coalesce(title, '')), 'A')) STORED
    """

    alter table(:forums_posts), do: add(:search_vector, :tsvector)

    # "The thread's first post" (the triggers below, title-only search) is
    # one index probe instead of sorting the thread's posts.
    create index(:forums_posts, [:thread_id, :inserted_at, :id])

    execute """
    CREATE FUNCTION forums_posts_search_vector() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector := to_tsvector('english', coalesce(NEW.body, ''));

      IF NOT EXISTS (
        SELECT 1 FROM forums_posts p
        WHERE p.thread_id = NEW.thread_id AND p.id <> NEW.id
          AND (p.inserted_at, p.id) < (NEW.inserted_at, NEW.id)
      ) THEN
        NEW.search_vector := NEW.search_vector ||
          (SELECT t.search_vector FROM forums_threads t WHERE t.id = NEW.thread_id);
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER forums_posts_search_vector
      BEFORE INSERT OR UPDATE OF body ON forums_posts
      FOR EACH ROW EXECUTE FUNCTION forums_posts_search_vector()
    """

    # A renamed thread re-indexes its first post (touching body fires the
    # trigger above).
    execute """
    CREATE FUNCTION forums_threads_title_changed() RETURNS trigger AS $$
    BEGIN
      UPDATE forums_posts SET body = body
      WHERE id = (
        SELECT p.id FROM forums_posts p WHERE p.thread_id = NEW.id
        ORDER BY p.inserted_at, p.id LIMIT 1
      );
      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER forums_threads_title_changed
      AFTER UPDATE OF title ON forums_threads
      FOR EACH ROW WHEN (OLD.title IS DISTINCT FROM NEW.title)
      EXECUTE FUNCTION forums_threads_title_changed()
    """

    execute "UPDATE forums_posts SET body = body"

    create index(:forums_threads, [:search_vector], using: :gin)
    create index(:forums_posts, [:search_vector], using: :gin)
  end

  def down do
    execute "DROP TRIGGER forums_threads_title_changed ON forums_threads"
    execute "DROP FUNCTION forums_threads_title_changed()"
    execute "DROP TRIGGER forums_posts_search_vector ON forums_posts"
    execute "DROP FUNCTION forums_posts_search_vector()"
    alter table(:forums_posts), do: remove(:search_vector)
    alter table(:forums_threads), do: remove(:search_vector)
    drop index(:forums_posts, [:thread_id, :inserted_at, :id])
  end
end
