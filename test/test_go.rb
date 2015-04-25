#!/usr/bin/env ruby
# encoding: utf-8

require 'minitest/autorun'
require 'fileutils'

DEFAULT_TIMEOUT = 20

base = File.expand_path('../../', __FILE__)
Dir.chdir base
FZF = "#{base}/bin/fzf"

class NilClass
  def include? str
    false
  end

  def start_with? str
    false
  end

  def end_with? str
    false
  end
end

def wait
  since = Time.now
  while Time.now - since < DEFAULT_TIMEOUT
    return if yield
    sleep 0.05
  end
  throw 'timeout'
end

class Shell
  class << self
    def bash
      'PS1= PROMPT_COMMAND= bash --rcfile ~/.fzf.bash'
    end

    def zsh
      FileUtils.mkdir_p '/tmp/fzf-zsh'
      FileUtils.cp File.expand_path('~/.fzf.zsh'), '/tmp/fzf-zsh/.zshrc'
      'PS1= PROMPT_COMMAND= HISTSIZE=100 ZDOTDIR=/tmp/fzf-zsh zsh'
    end
  end
end

class Tmux
  TEMPNAME = '/tmp/fzf-test.txt'

  attr_reader :win

  def initialize shell = :bash
    @win =
      case shell
      when :bash
        go("new-window -d -P -F '#I' '#{Shell.bash}'").first
      when :zsh
        go("new-window -d -P -F '#I' '#{Shell.zsh}'").first
      when :fish
        go("new-window -d -P -F '#I' 'fish'").first
      else
        raise "Unknown shell: #{shell}"
      end
    @lines = `tput lines`.chomp.to_i

    if shell == :fish
      send_keys('function fish_prompt; end; clear', :Enter)
      self.until { |lines| lines.empty? }
    end
  end

  def closed?
    !go("list-window -F '#I'").include?(win)
  end

  def close
    send_keys 'C-c', 'C-u', 'exit', :Enter
    wait { closed? }
  end

  def kill
    go("kill-window -t #{win} 2> /dev/null")
  end

  def send_keys *args
    target =
      if args.last.is_a?(Hash)
        hash = args.pop
        go("select-window -t #{win}")
        "#{win}.#{hash[:pane]}"
      else
        win
      end
    args = args.map { |a| %{"#{a}"} }.join ' '
    go("send-keys -t #{target} #{args}")
  end

  def capture pane = 0
    File.unlink TEMPNAME while File.exists? TEMPNAME
    wait do
      go("capture-pane -t #{win}.#{pane} \\; save-buffer #{TEMPNAME} 2> /dev/null")
      $?.exitstatus == 0
    end
    File.read(TEMPNAME).split($/)[0, @lines].reverse.drop_while(&:empty?).reverse
  end

  def until pane = 0
    lines = nil
    wait do
      lines = capture(pane)
      class << lines
        def item_count
          self[-2] ? self[-2].strip.split('/').last.to_i : 0
        end
      end
      yield lines
    end
    lines
  end

  def prepare
    tries = 0
    begin
      self.send_keys 'C-u', 'hello'
      self.until { |lines| lines[-1].end_with?('hello') }
    rescue Exception
      (tries += 1) < 5 ? retry : raise
    end
    self.send_keys 'C-u'
  end
private
  def go *args
    %x[tmux #{args.join ' '}].split($/)
  end
end

class TestBase < Minitest::Test
  TEMPNAME = '/tmp/output'

  attr_reader :tmux

  def setup
    ENV.delete 'FZF_DEFAULT_OPTS'
    ENV.delete 'FZF_DEFAULT_COMMAND'
    File.unlink TEMPNAME while File.exists?(TEMPNAME)
  end

  def readonce
    wait { File.exists?(TEMPNAME) }
    File.read(TEMPNAME)
  ensure
    File.unlink TEMPNAME while File.exists?(TEMPNAME)
  end

  def fzf(*opts)
    fzf!(*opts) + " > #{TEMPNAME}.tmp; mv #{TEMPNAME}.tmp #{TEMPNAME}"
  end

  def fzf!(*opts)
    opts = opts.map { |o|
      case o
      when Symbol
        o = o.to_s
        o.length > 1 ? "--#{o.gsub('_', '-')}" : "-#{o}"
      when String, Numeric
        o.to_s
      else
        nil
      end
    }.compact
    "#{FZF} #{opts.join ' '}"
  end
end

class TestGoFZF < TestBase
  def setup
    super
    @tmux = Tmux.new
  end

  def teardown
    @tmux.kill
  end

  def test_vanilla
    tmux.send_keys "seq 1 100000 | #{fzf}", :Enter
    tmux.until { |lines| lines.last =~ /^>/ && lines[-2] =~ /^  100000/ }
    lines = tmux.capture
    assert_equal '  2',             lines[-4]
    assert_equal '> 1',             lines[-3]
    assert_equal '  100000/100000', lines[-2]
    assert_equal '>',               lines[-1]

    # Testing basic key bindings
    tmux.send_keys '99', 'C-a', '1', 'C-f', '3', 'C-b', 'C-h', 'C-u', 'C-e', 'C-y', 'C-k', 'Tab', 'BTab'
    tmux.until { |lines| lines[-2] == '  856/100000' }
    lines = tmux.capture
    assert_equal '> 1391',       lines[-4]
    assert_equal '  391',        lines[-3]
    assert_equal '  856/100000', lines[-2]
    assert_equal '> 391',        lines[-1]

    tmux.send_keys :Enter
    tmux.close
    assert_equal '1391', readonce.chomp
  end

  def test_fzf_default_command
    tmux.send_keys "FZF_DEFAULT_COMMAND='echo hello' #{fzf}", :Enter
    tmux.until { |lines| lines.last =~ /^>/ }

    tmux.send_keys :Enter
    tmux.close
    assert_equal 'hello', readonce.chomp
  end

  def test_key_bindings
    tmux.send_keys "#{FZF} -q 'foo bar foo-bar'", :Enter
    tmux.until { |lines| lines.last =~ /^>/ }

    # CTRL-A
    tmux.send_keys "C-A", "("
    tmux.until { |lines| lines.last == '> (foo bar foo-bar' }

    # META-F
    tmux.send_keys :Escape, :f, ")"
    tmux.until { |lines| lines.last == '> (foo) bar foo-bar' }

    # CTRL-B
    tmux.send_keys "C-B", "var"
    tmux.until { |lines| lines.last == '> (foovar) bar foo-bar' }

    # Left, CTRL-D
    tmux.send_keys :Left, :Left, "C-D"
    tmux.until { |lines| lines.last == '> (foovr) bar foo-bar' }

    # META-BS
    tmux.send_keys :Escape, :BSpace
    tmux.until { |lines| lines.last == '> (r) bar foo-bar' }

    # CTRL-Y
    tmux.send_keys "C-Y", "C-Y"
    tmux.until { |lines| lines.last == '> (foovfoovr) bar foo-bar' }

    # META-B
    tmux.send_keys :Escape, :b, :Space, :Space
    tmux.until { |lines| lines.last == '> (  foovfoovr) bar foo-bar' }

    # CTRL-F / Right
    tmux.send_keys 'C-F', :Right, '/'
    tmux.until { |lines| lines.last == '> (  fo/ovfoovr) bar foo-bar' }

    # CTRL-H / BS
    tmux.send_keys 'C-H', :BSpace
    tmux.until { |lines| lines.last == '> (  fovfoovr) bar foo-bar' }

    # CTRL-E
    tmux.send_keys "C-E", 'baz'
    tmux.until { |lines| lines.last == '> (  fovfoovr) bar foo-barbaz' }

    # CTRL-U
    tmux.send_keys "C-U"
    tmux.until { |lines| lines.last == '>' }

    # CTRL-Y
    tmux.send_keys "C-Y"
    tmux.until { |lines| lines.last == '> (  fovfoovr) bar foo-barbaz' }

    # CTRL-W
    tmux.send_keys "C-W", "bar-foo"
    tmux.until { |lines| lines.last == '> (  fovfoovr) bar bar-foo' }

    # META-D
    tmux.send_keys :Escape, :b, :Escape, :b, :Escape, :d, "C-A", "C-Y"
    tmux.until { |lines| lines.last == '> bar(  fovfoovr) bar -foo' }

    # CTRL-M
    tmux.send_keys "C-M"
    tmux.until { |lines| lines.last !~ /^>/ }
    tmux.close
  end

  def test_multi_order
    tmux.send_keys "seq 1 10 | #{fzf :multi}", :Enter
    tmux.until { |lines| lines.last =~ /^>/ }

    tmux.send_keys :Tab, :Up, :Up, :Tab, :Tab, :Tab, # 3, 2
                   'C-K', 'C-K', 'C-K', 'C-K', :BTab, :BTab, # 5, 6
                   :PgUp, 'C-J', :Down, :Tab, :Tab # 8, 7
    tmux.until { |lines| lines[-2].include? '(6)' }
    tmux.send_keys "C-M"
    assert_equal %w[3 2 5 6 8 7], readonce.split($/)
    tmux.close
  end

  def test_with_nth
    [true, false].each do |multi|
      tmux.send_keys "(echo '  1st 2nd 3rd/';
                       echo '  first second third/') |
                       #{fzf multi && :multi, :x, :nth, 2, :with_nth, '2,-1,1'}",
                      :Enter
      tmux.until { |lines| lines[-2].include?('2/2') }

      # Transformed list
      lines = tmux.capture
      assert_equal '  second third/first', lines[-4]
      assert_equal '> 2nd 3rd/1st',        lines[-3]

      # However, the output must not be transformed
      if multi
        tmux.send_keys :BTab, :BTab, :Enter
        assert_equal ['  1st 2nd 3rd/', '  first second third/'], readonce.split($/)
      else
        tmux.send_keys '^', '3'
        tmux.until { |lines| lines[-2].include?('1/2') }
        tmux.send_keys :Enter
        assert_equal ['  1st 2nd 3rd/'], readonce.split($/)
      end
    end
  end

  def test_scroll
    [true, false].each do |rev|
      tmux.send_keys "seq 1 100 | #{fzf rev && :reverse}", :Enter
      tmux.until { |lines| lines.include? '  100/100' }
      tmux.send_keys *110.times.map { rev ? :Down : :Up }
      tmux.until { |lines| lines.include? '> 100' }
      tmux.send_keys :Enter
      assert_equal '100', readonce.chomp
    end
  end

  def test_select_1
    tmux.send_keys "seq 1 100 | #{fzf :with_nth, '..,..', :print_query, :q, 5555, :'1'}", :Enter
    assert_equal ['5555', '55'], readonce.split($/)
  end

  def test_exit_0
    tmux.send_keys "seq 1 100 | #{fzf :with_nth, '..,..', :print_query, :q, 555555, :'0'}", :Enter
    assert_equal ['555555'], readonce.split($/)
  end

  def test_select_1_exit_0_fail
    [:'0', :'1', [:'1', :'0']].each do |opt|
      tmux.send_keys "seq 1 100 | #{fzf :print_query, :multi, :q, 5, *opt}", :Enter
      tmux.until { |lines| lines.last =~ /^> 5/ }
      tmux.send_keys :BTab, :BTab, :BTab, :Enter
      assert_equal ['5', '5', '15', '25'], readonce.split($/)
    end
  end

  def test_query_unicode
    tmux.send_keys "(echo abc; echo 가나다) | #{fzf :query, '가다'}", :Enter
    tmux.until { |lines| lines[-2].include? '1/2' }
    tmux.send_keys :Enter
    assert_equal ['가나다'], readonce.split($/)
  end

  def test_sync
    tmux.send_keys "seq 1 100 | #{fzf! :multi} | awk '{print \\$1 \\$1}' | #{fzf :sync}", :Enter
    tmux.until { |lines| lines[-1] == '>' }
    tmux.send_keys 9
    tmux.until { |lines| lines[-2] == '  19/100' }
    tmux.send_keys :BTab, :BTab, :BTab, :Enter
    tmux.until { |lines| lines[-1] == '>' }
    tmux.send_keys 'C-K', :Enter
    assert_equal ['1919'], readonce.split($/)
  end

  def test_tac
    tmux.send_keys "seq 1 1000 | #{fzf :tac, :multi}", :Enter
    tmux.until { |lines| lines[-2].include? '1000/1000' }
    tmux.send_keys :BTab, :BTab, :BTab, :Enter
    assert_equal %w[1000 999 998], readonce.split($/)
  end

  def test_tac_sort
    tmux.send_keys "seq 1 1000 | #{fzf :tac, :multi}", :Enter
    tmux.until { |lines| lines[-2].include? '1000/1000' }
    tmux.send_keys '99'
    tmux.send_keys :BTab, :BTab, :BTab, :Enter
    assert_equal %w[99 999 998], readonce.split($/)
  end

  def test_tac_nosort
    tmux.send_keys "seq 1 1000 | #{fzf :tac, :no_sort, :multi}", :Enter
    tmux.until { |lines| lines[-2].include? '1000/1000' }
    tmux.send_keys '00'
    tmux.send_keys :BTab, :BTab, :BTab, :Enter
    assert_equal %w[1000 900 800], readonce.split($/)
  end

  def test_expect
    test = lambda do |key, feed, expected = key|
      tmux.send_keys "seq 1 100 | #{fzf :expect, key}", :Enter
      tmux.until { |lines| lines[-2].include? '100/100' }
      tmux.send_keys '55'
      tmux.send_keys *feed
      assert_equal [expected, '55'], readonce.split($/)
    end
    test.call 'ctrl-t', 'C-T'
    test.call 'ctrl-t', 'Enter', ''
    test.call 'alt-c', [:Escape, :c]
    test.call 'f1', 'f1'
    test.call 'f2', 'f2'
    test.call 'f3', 'f3'
    test.call 'f2,f4', 'f2', 'f2'
    test.call 'f2,f4', 'f4', 'f4'
    test.call '@', '@'
  end

  def test_expect_print_query
    tmux.send_keys "seq 1 100 | #{fzf '--expect=alt-z', :print_query}", :Enter
    tmux.until { |lines| lines[-2].include? '100/100' }
    tmux.send_keys '55'
    tmux.send_keys :Escape, :z
    assert_equal ['55', 'alt-z', '55'], readonce.split($/)
  end

  def test_expect_print_query_select_1
    tmux.send_keys "seq 1 100 | #{fzf '-q55 -1 --expect=alt-z --print-query'}", :Enter
    assert_equal ['55', '', '55'], readonce.split($/)
  end

  def test_toggle_sort
    tmux.send_keys "seq 1 111 | #{fzf '-m +s --tac --toggle-sort=ctrl-r -q11'}", :Enter
    tmux.until { |lines| lines[-3].include? '> 111' }
    tmux.send_keys :Tab
    tmux.until { |lines| lines[-2].include? '4/111   (1)' }
    tmux.send_keys 'C-R'
    tmux.until { |lines| lines[-3].include? '> 11' }
    tmux.send_keys :Tab
    tmux.until { |lines| lines[-2].include? '4/111/S (2)' }
    tmux.send_keys :Enter
    assert_equal ['111', '11'], readonce.split($/)
  end

  def test_unicode_case
    tempname = TEMPNAME + Time.now.to_f.to_s
    writelines tempname, %w[строКА1 СТРОКА2 строка3 Строка4]
    assert_equal %w[СТРОКА2 Строка4], `cat #{tempname} | #{FZF} -fС`.split($/)
    assert_equal %w[строКА1 СТРОКА2 строка3 Строка4], `cat #{tempname} | #{FZF} -fс`.split($/)
  rescue
    File.unlink tempname
  end

  def test_tiebreak
    tempname = TEMPNAME + Time.now.to_f.to_s
    input = %w[
      --foobar--------
      -----foobar---
      ----foobar--
      -------foobar-
    ]
    writelines tempname, input

    assert_equal input, `cat #{tempname} | #{FZF} -ffoobar --tiebreak=index`.split($/)

    by_length = %w[
      ----foobar--
      -----foobar---
      -------foobar-
      --foobar--------
    ]
    assert_equal by_length, `cat #{tempname} | #{FZF} -ffoobar`.split($/)
    assert_equal by_length, `cat #{tempname} | #{FZF} -ffoobar --tiebreak=length`.split($/)

    by_begin = %w[
      --foobar--------
      ----foobar--
      -----foobar---
      -------foobar-
    ]
    assert_equal by_begin, `cat #{tempname} | #{FZF} -ffoobar --tiebreak=begin`.split($/)
    assert_equal by_begin, `cat #{tempname} | #{FZF} -f"!z foobar" -x --tiebreak begin`.split($/)

    assert_equal %w[
      -------foobar-
      ----foobar--
      -----foobar---
      --foobar--------
    ], `cat #{tempname} | #{FZF} -ffoobar --tiebreak end`.split($/)

    assert_equal input, `cat #{tempname} | #{FZF} -f"!z" -x --tiebreak end`.split($/)
  rescue
    File.unlink tempname
  end

  def test_invalid_cache
    tmux.send_keys "(echo d; echo D; echo x) | #{fzf '-q d'}", :Enter
    tmux.until { |lines| lines[-2].include? '2/3' }
    tmux.send_keys :BSpace
    tmux.until { |lines| lines[-2].include? '3/3' }
    tmux.send_keys :D
    tmux.until { |lines| lines[-2].include? '1/3' }
    tmux.send_keys :Enter
  end

  def test_smart_case_for_each_term
    assert_equal 1, `echo Foo bar | #{FZF} -x -f "foo Fbar" | wc -l`.to_i
  end

private
  def writelines path, lines
    File.unlink path while File.exists? path
    File.open(path, 'w') { |f| f << lines.join($/) }
  end
end

module TestShell
  def setup
    super
  end

  def teardown
    @tmux.kill
  end

  def test_ctrl_t
    tmux.prepare
    tmux.send_keys 'C-t', pane: 0
    lines = tmux.until(1) { |lines| lines.item_count > 0 }
    expected = lines.values_at(-3, -4).map { |line| line[2..-1] }.join(' ')
    tmux.send_keys :BTab, :BTab, :Enter, pane: 1
    tmux.until(0) { |lines| lines[-1].include? expected }
    tmux.send_keys 'C-c'

    # FZF_TMUX=0
    new_shell
    tmux.send_keys 'C-t', pane: 0
    lines = tmux.until(0) { |lines| lines.item_count > 0 }
    expected = lines.values_at(-3, -4).map { |line| line[2..-1] }.join(' ')
    tmux.send_keys :BTab, :BTab, :Enter, pane: 0
    tmux.until(0) { |lines| lines[-1].include? expected }
    tmux.send_keys 'C-c', 'C-d'
  end

  def test_alt_c
    tmux.prepare
    tmux.send_keys :Escape, :c, pane: 0
    lines = tmux.until(1) { |lines| lines.item_count > 0 }
    expected = lines[-3][2..-1]
    p expected
    tmux.send_keys :Enter, pane: 1
    tmux.prepare
    tmux.send_keys :pwd, :Enter
    tmux.until { |lines| p lines; lines[-1].end_with?(expected) }
  end

  def test_ctrl_r
    tmux.prepare
    tmux.send_keys 'echo 1st', :Enter; tmux.prepare
    tmux.send_keys 'echo 2nd', :Enter; tmux.prepare
    tmux.send_keys 'echo 3d',  :Enter; tmux.prepare
    tmux.send_keys 'echo 3rd', :Enter; tmux.prepare
    tmux.send_keys 'echo 4th', :Enter; tmux.prepare
    tmux.send_keys 'C-r', pane: 0
    tmux.until(1) { |lines| lines.item_count > 0 }
    tmux.send_keys '3d', pane: 1
    tmux.until(1) { |lines| lines[-3].end_with? 'echo 3rd' } # --no-sort
    tmux.send_keys :Enter, pane: 1
    tmux.until { |lines| lines[-1] == 'echo 3rd' }
    tmux.send_keys :Enter
    tmux.until { |lines| lines[-1] == '3rd' }
  end
end

class TestBash < TestBase
  include TestShell

  def new_shell
    tmux.send_keys "FZF_TMUX=0 #{Shell.bash}", :Enter
    tmux.prepare
  end

  def setup
    super
    @tmux = Tmux.new :bash
  end

  def test_file_completion
    tmux.send_keys 'mkdir -p /tmp/fzf-test; touch /tmp/fzf-test/{1..100}', :Enter
    tmux.prepare
    tmux.send_keys 'cat /tmp/fzf-test/10**', :Tab, pane: 0
    tmux.until(1) { |lines| lines.item_count > 0 }
    tmux.send_keys :BTab, :BTab, :Enter
    tmux.until do |lines|
      tmux.send_keys 'C-L'
      lines[-1].include?('/tmp/fzf-test/10') &&
      lines[-1].include?('/tmp/fzf-test/100')
    end
  end

  def test_dir_completion
    tmux.send_keys 'mkdir -p /tmp/fzf-test/d{1..100}; touch /tmp/fzf-test/d55/xxx', :Enter
    tmux.prepare
    tmux.send_keys 'cd /tmp/fzf-test/**', :Tab, pane: 0
    tmux.until(1) { |lines| lines.item_count > 0 }
    tmux.send_keys :BTab, :BTab # BTab does not work here
    tmux.send_keys 55
    tmux.until(1) { |lines| lines[-2].start_with? '  1/' }
    tmux.send_keys :Enter
    tmux.until do |lines|
      tmux.send_keys 'C-L'
      lines[-1] == 'cd /tmp/fzf-test/d55/'
    end
    tmux.send_keys :xx
    tmux.until { |lines| lines[-1] == 'cd /tmp/fzf-test/d55/xx' }

    # Should not match regular files
    tmux.send_keys :Tab
    tmux.until { |lines| lines[-1] == 'cd /tmp/fzf-test/d55/xx' }

    # Fail back to plusdirs
    tmux.send_keys :BSpace, :BSpace, :BSpace
    tmux.until { |lines| lines[-1] == 'cd /tmp/fzf-test/d55' }
    tmux.send_keys :Tab
    tmux.until { |lines| lines[-1] == 'cd /tmp/fzf-test/d55/' }
  end

  def test_process_completion
    tmux.send_keys 'sleep 12345 &', :Enter
    lines = tmux.until { |lines| lines[-1].start_with? '[1]' }
    pid = lines[-1].split.last
    tmux.prepare
    tmux.send_keys 'kill ', :Tab, pane: 0
    tmux.until(1) { |lines| lines.item_count > 0 }
    tmux.send_keys 'sleep12345'
    tmux.until(1) { |lines| lines[-3].include? 'sleep 12345' }
    tmux.send_keys :Enter
    tmux.until do |lines|
      tmux.send_keys 'C-L'
      lines[-1] == "kill #{pid}"
    end
  end
end

class TestZsh < TestBase
  include TestShell

  def new_shell
    tmux.send_keys "FZF_TMUX=0 #{Shell.zsh}", :Enter
    tmux.prepare
  end

  def setup
    super
    @tmux = Tmux.new :zsh
  end
end

class TestFish < TestBase
  include TestShell

  def new_shell
    tmux.send_keys 'env FZF_TMUX=0 fish', :Enter
    tmux.send_keys 'function fish_prompt; end; clear', :Enter
    tmux.until { |lines| lines.empty? }
  end

  def setup
    super
    @tmux = Tmux.new :fish
  end
end

