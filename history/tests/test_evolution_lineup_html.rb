# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'uri'
require 'cgi'

class TestEvolutionLineupHtml < Test::Unit::TestCase
  CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe'
  HTML = File.expand_path('../../tools/history/evolution_lineup/lineup_dialog.html', __dir__)
  CSS = File.expand_path('../../bom_engine/ui/bomc_theme.css', __dir__)

  def render(engine, label, filename)
    omit 'Headless Chrome unavailable' unless File.file?(CHROME)
    Dir.mktmpdir('evolution-ui-') do |folder|
      FileUtils.cp(CSS, File.join(folder, 'bomc_theme.css'))
      source = File.read(HTML)
      stub = '<script>window.sketchup={onReady:function(){},browse:function(){},cancel:function(){},export:function(value){window.sent=JSON.parse(value)}};</script>'
      source.sub!('<script>', stub + '<script>')
      qa = <<~JS
        <script>
          setConfig({id:'qa',title:#{label.to_json},engine:#{engine.to_json},sha:'a'.repeat(64),
            formatVersion:'qa',state:'uncertified',output_path:#{filename.to_json}});
          document.querySelector('input[name="profile-choice"][value="exact"]').checked=true;
          updateProfilePath();
          document.querySelector('input[name="batch-mode"][value="manual"]').checked=true;
          refreshBatchMode();
          document.getElementById('batch-size').value='8192';
          document.getElementById('export').click();
          window.qa={sent:window.sent,text:document.body.innerText,
            choices:Array.from(document.querySelectorAll('input[name="profile-choice"]')).map(input=>input.value)};
          document.body.setAttribute('data-qa',encodeURIComponent(JSON.stringify(window.qa)));
        </script>
      JS
      source.sub!('</body>', "#{qa}</body>")
      path = File.join(folder, 'dialog.html')
      File.write(path, source)
      stdout, stderr, status = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
        '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome')}",
        '--window-size=680,720', '--virtual-time-budget=1000', '--dump-dom', "file:///#{path.tr('\\', '/')}")
      assert status.success?, stderr.lines.last(4).join
      payload = stdout[/<body[^>]*data-qa="([^"]*)"/m, 1]
      assert_not_nil payload, stderr.lines.last(4).join
      if ENV['EVOLUTION_QA_SCREENSHOT_DIR'] && engine == 'e2'
        screenshot = File.join(ENV.fetch('EVOLUTION_QA_SCREENSHOT_DIR'), 'e2-dialog.png')
        _out, error, result = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
          '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome-shot')}",
          '--window-size=680,720', "--screenshot=#{screenshot}", "file:///#{path.tr('\\', '/')}")
        assert result.success? && File.file?(screenshot), error.lines.last(4).join
      end
      JSON.parse(URI.decode_www_form_component(CGI.unescapeHTML(payload)))
    end
  end

  def test_active_e2_e3_use_exact_visual_all_and_shared_manual_batch
    [['e2', 'Canonical JSON 3.1 + Gzip', '.json.gz'], ['e3', 'CleanPKG 1.1', '.cleanpkg']].each do |engine, label, extension|
      result = render(engine, label, 'D:/out/model' + extension)
      assert_equal %w[exact visual all], result['choices']
      assert_equal 'exact', result.dig('sent', 'profile')
      assert_equal 'manual', result.dig('sent', 'batch_mode')
      assert_equal 8_192, result.dig('sent', 'batch_size')
      assert_equal "D:/out/model__#{engine.upcase}__EXACT#{extension}", result.dig('sent', 'output_path')
      assert_include result['text'], label
    end
  end
end
