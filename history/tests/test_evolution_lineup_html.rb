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

  def render(kind, label, filename)
    omit 'Headless Chrome unavailable' unless File.file?(CHROME)
    Dir.mktmpdir('evolution-ui-') do |folder|
      FileUtils.cp(CSS, File.join(folder, 'bomc_theme.css'))
      source = File.read(HTML)
      stub = '<script>window.sketchup={onReady:function(){},browse:function(){},cancel:function(){},export:function(value){window.sent=JSON.parse(value)}};</script>'
      source.sub!('<script>', stub + '<script>')
      qa = <<~JS
        <script>
          setConfig({id:'qa',title:#{label.to_json},kind:#{kind.to_json},sha:'a'.repeat(64),
            state:'uncertified',output_path:#{filename.to_json}});
          document.getElementById('batch').value='8192';
          document.getElementById('export').click();
          window.qa={sent:window.sent,text:document.body.innerText,
            tieredHidden:document.getElementById('tiered').offsetParent===null,
            canonicalHidden:document.getElementById('canonical').offsetParent===null,
            cleanpkgHidden:document.getElementById('cleanpkg').offsetParent===null};
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
      if ENV['EVOLUTION_QA_SCREENSHOT_DIR'] && kind == 'canonical_v3'
        screenshot = File.join(ENV.fetch('EVOLUTION_QA_SCREENSHOT_DIR'), 'e2-dialog.png')
        _out, error, result = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
          '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome-shot')}",
          '--window-size=680,720', "--screenshot=#{screenshot}", "file:///#{path.tr('\\', '/')}")
        assert result.success? && File.file?(screenshot), error.lines.last(4).join
      end
      JSON.parse(URI.decode_www_form_component(CGI.unescapeHTML(payload)))
    end
  end

  def test_each_historical_generation_has_its_own_controls_and_shared_batch
    e1 = render('tiered_json', 'E1 — JSON Visual / Standard / Full', 'D:/out/model.json')
    assert_equal 8_192, e1.dig('sent', 'batch_size')
    assert_equal false, e1['tieredHidden']
    assert_equal true, e1['canonicalHidden']
    assert_equal true, e1['cleanpkgHidden']

    e2 = render('canonical_v3', 'E2 — Canonical JSON v3 + Gzip', 'D:/out/model.json.gz')
    assert_equal 8_192, e2.dig('sent', 'batch_size')
    assert_equal 'D:/out/model__SBE-2026.07.16-01_canonical.json.gz', e2.dig('sent', 'output_path')
    assert_equal true, e2['tieredHidden']
    assert_equal false, e2['canonicalHidden']
    assert_include e2['text'], 'selalu dikompresi Gzip'

    e3 = render('cleanpkg', 'E3 — CleanPKG Binary Container', 'D:/out/model.cleanpkg')
    assert_equal 8_192, e3.dig('sent', 'batch_size')
    assert_equal true, e3['canonicalHidden']
    assert_equal false, e3['cleanpkgHidden']
    assert_include e3['text'], 'Tidak ada profil Visual/Research/Exact'
  end
end
