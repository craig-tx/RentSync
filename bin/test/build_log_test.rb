# frozen_string_literal: true

# Tests for bin/build-log. Plain Ruby (minitest ships with Ruby): ruby bin/test/build_log_test.rb
require "minitest/autorun"
require "tmpdir"
require "stringio"
require "open3"
load File.expand_path("../build-log", __dir__)

class BuildLogTest < Minitest::Test
  LOG = <<~MD
    # AI Build Log

    ### 2026-10-20: an archived entry

    - **Done:** things.

    ## Entries by PR

    <!-- One slot per PR number; see bin/build-log. -->

    <!-- PR #42: free -->

    <!-- PR #43: free -->

    <!-- PR #44: free -->

  MD

  ENTRY = "### 2026-10-28: slots\n\n- **Done:** the slot system.\n"

  def run_cli(args, text: LOG, stdin: "")
    Dir.mktmpdir do |dir|
      file = File.join(dir, "log.md")
      File.binwrite(file, text)
      out = StringIO.new
      code = BuildLog.main(args, file: file, stdin: StringIO.new(stdin), out: out)
      [code, out.string, File.binread(file)]
    end
  end

  def test_parse_and_render_round_trip_byte_for_byte
    head, slots = BuildLog.parse(LOG)
    assert_equal LOG, BuildLog.render(head, slots)
    assert_equal [42, 43, 44], slots.map(&:number)
  end

  def test_fill_writes_only_its_own_slot
    code, out, after = run_cli(%w[fill 43], stdin: ENTRY)
    assert_equal 0, code, out
    expected = LOG.sub("<!-- PR #43: free -->\n", "<!-- PR #43 -->\n#{ENTRY}")
    assert_equal expected, after
  end

  def test_fill_reads_an_entry_file
    Dir.mktmpdir do |dir|
      entry = File.join(dir, "entry.md")
      File.binwrite(entry, ENTRY.gsub("\n", "\r\n")) # written on Windows
      code, out, after = run_cli(["fill", "42", entry])
      assert_equal 0, code, out
      assert_includes after, "<!-- PR #42 -->\n### 2026-10-28: slots\n"
      refute_includes after, "\r"
    end
  end

  def test_fill_refuses_a_missing_slot_a_filled_slot_and_an_entry_without_a_heading
    code, out, = run_cli(%w[fill 99], stdin: ENTRY)
    assert_equal [1, true], [code, out.include?("no slot for PR #99")]

    filled = LOG.sub("<!-- PR #42: free -->\n", "<!-- PR #42 -->\n#{ENTRY}")
    code, out, = run_cli(%w[fill 42], text: filled, stdin: ENTRY)
    assert_equal [1, true], [code, out.include?("already filled")]

    code, out, = run_cli(%w[fill 42], stdin: "no heading\n")
    assert_equal [1, true], [code, out.include?("### ")]
  end

  def test_check_counts_entries_and_free_slots
    filled = LOG.sub("<!-- PR #42: free -->\n", "<!-- PR #42 -->\n#{ENTRY}")
    code, out, after = run_cli(%w[check], text: filled)
    assert_equal 0, code
    assert_includes out, "1 entries, 2 free slots ahead"
    assert_includes out, "::warning" # 2 < WARN_BELOW
    assert_equal filled, after, "check must not rewrite the file"
  end

  def test_check_rejects_broken_slots
    [LOG.sub("#43", "#41"), LOG.sub("<!-- PR #43: free -->\n", "<!-- PR #43: free -->\nstray text\n"),
     LOG.sub("<!-- PR #43: free -->\n", "<!-- PR #43 -->\nno heading\n")].each do |broken|
      code, out, = run_cli(%w[check], text: broken)
      assert_equal 1, code, "accepted:\n#{broken}\n#{out}"
    end
  end

  def test_top_up_leaves_slots_ahead_free_after_the_last_entry
    filled = LOG.sub("<!-- PR #44: free -->\n", "<!-- PR #44 -->\n#{ENTRY}")
    code, out, after = run_cli(%w[top-up], text: filled)
    assert_equal 0, code, out
    _, slots = BuildLog.parse(after)
    assert_equal BuildLog::SLOTS_AHEAD, BuildLog.free_ahead(slots)
    assert_equal (42..(44 + BuildLog::SLOTS_AHEAD)).to_a, slots.map(&:number)
    assert after.start_with?(filled), "top-up must only append"
  end

  # The point of the slots: two PRs that fill neighbouring slots merge without a conflict.
  def test_two_branches_filling_neighbouring_slots_merge_cleanly
    Dir.mktmpdir do |dir|
      git = ->(*args) { Open3.capture2e("git", "-C", dir, *args).tap { |o, s| assert s.success?, o } }
      git.("init", "-q", "-b", "main")
      git.("config", "user.email", "t@example.test")
      git.("config", "user.name", "t")
      git.("config", "core.autocrlf", "false")
      file = File.join(dir, "log.md")
      File.binwrite(file, LOG)
      git.("add", ".")
      git.("commit", "-qm", "base")
      [[42, "a"], [43, "b"]].each do |number, branch|
        git.("switch", "-q", "-c", branch, "main")
        File.binwrite(file, BuildLog.fill(File.binread(file), number, ENTRY.sub("slots", "entry #{number}")))
        git.("commit", "-qam", branch)
      end
      git.("switch", "-q", "main")
      git.("merge", "-q", "--no-edit", "a")
      git.("merge", "-q", "--no-edit", "b")
      merged = File.binread(file)
      assert_includes merged, "<!-- PR #42 -->\n### 2026-10-28: entry 42\n"
      assert_includes merged, "<!-- PR #43 -->\n### 2026-10-28: entry 43\n"
    end
  end
end
