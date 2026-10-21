# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'uri'
require 'cgi'

class TestEvolutionActiveHtmlSmoke < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)
  CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe'

  def test_canonical_and_cleanpkg_match_bomc_profile_layout_and_all_path
    omit 'Google Chrome headless unavailable' unless File.file?(CHROME)
    { 'e2' => '.json.gz', 'e3' => '.cleanpkg' }.each do |engine, extension|
      Dir.mktmpdir('evolution-active-html-', Gem.win_platform? ? 'D:/projects/sibambo/scratch' : Dir.tmpdir) do |folder|
        FileUtils.cp(File.join(ROOT, 'bom_engine/ui/bomc_theme.css'), File.join(folder, 'bomc_theme.css'))
        source = File.read(File.join(ROOT, 'tools/history/evolution_lineup/lineup_dialog.html'))
        source.sub!('<script>', '<script>window.sketchup={onReady(){},browse(){},cancel(){},export(v){window.sent=JSON.parse(v)}};</script><script>')
        script = <<~JS
          <script>
            setConfig({engine:#{engine.to_json},title:'Format',sha:'a'.repeat(64),formatVersion:'1',output_path:#{"/tmp/model#{extension}".to_json}});
            var choices=Array.from(document.querySelectorAll('input[name="profile-choice"]'),e=>e.value);
            document.querySelector('input[name="profile-choice"][value="all"]').checked=true;
            updateProfilePath();
            document.getElementById('export').click();
            document.body.setAttribute('data-qa',encodeURIComponent(JSON.stringify({choices,sent:window.sent})));
          </script>
        JS
        source.sub!('</body>', "#{script}</body>")
        html = File.join(folder, 'dialog.html')
        File.write(html, source)
        stdout, stderr, status = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
          '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome')}",
          '--virtual-time-budget=1000', '--dump-dom', "file:///#{html.tr('\\', '/')}")
        assert status.success?, stderr.lines.last(4).join
        token = stdout[/<body[^>]*data-qa="([^"]*)"/m, 1]
        assert_not_nil token, stderr.lines.last(4).join
        data = JSON.parse(URI.decode_www_form_component(CGI.unescapeHTML(token)))
        assert_equal %w[exact visual all], data.fetch('choices')
        assert_equal 'all', data.dig('sent', 'profile')
        assert_equal '/tmp/model', data.dig('sent', 'output_path')
        assert_equal 'auto', data.dig('sent', 'batch_mode')
      end
    end
  end
end
