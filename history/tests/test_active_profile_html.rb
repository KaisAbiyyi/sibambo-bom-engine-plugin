# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require 'uri'
require 'cgi'

class TestActiveProfileHtml < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  def inspect_dialog(relative, script)
    omit 'Set PLAYWRIGHT_MODULE to a locally installed Playwright module for Chromium UI proof' unless ENV['PLAYWRIGHT_MODULE']
    Dir.mktmpdir('active-profile-ui-') do |directory|
      FileUtils.cp(File.join(ROOT, 'bom_engine/ui/bomc_theme.css'), File.join(directory, 'bomc_theme.css'))
      html = File.read(File.join(ROOT, relative))
      stub = '<script>window.sketchup={ready(){},onReady(){},browse(){},cancel(){},export(value){window.sent=JSON.parse(value)}};</script>'
      html.sub!('<script>', stub + '<script>')
      html.sub!('<link rel="stylesheet" href="bomc_theme.css">', "<style>#{File.read(File.join(directory, 'bomc_theme.css'))}</style>")
      html.sub!('</body>', "<script>#{script};document.body.setAttribute('data-qa',encodeURIComponent(JSON.stringify(window.qa)));</script></body>")
      path = File.join(directory, 'dialog.html')
      File.write(path, html)
      driver = File.join(directory, 'inspect.cjs')
      File.write(driver, <<~'JS')
        const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
        (async () => {
          const browser = await chromium.launch({headless:true, ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE} : {})});
          try {
            const page = await browser.newPage();
            const errors = [];
            page.on('pageerror', error => errors.push(error.message));
            page.on('dialog', async dialog => { errors.push(dialog.message()); await dialog.dismiss(); });
            await page.setContent(require('node:fs').readFileSync(process.argv[2], 'utf8'));
            await page.waitForFunction(() => document.body.dataset.qa);
            const result = await page.evaluate(() => JSON.parse(decodeURIComponent(document.body.dataset.qa)));
            console.log(JSON.stringify({...result, scriptErrors:errors}));
          } finally { await browser.close(); }
        })().catch(error => { console.error(error); process.exitCode=1; });
      JS
      stdout, stderr, status = Open3.capture3('node', driver, path)
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal [], result.fetch('scriptErrors')
      result
    end
  end

  def test_bomc_dialog_exposes_exact_then_visual_and_export_all_has_two_profiles
    result = inspect_dialog('bom_engine/ui/bomc_export_dialog.html', <<~JS)
      setDefaultPath('/tmp/model.bomc');
      const choices=Array.from(document.querySelectorAll('input[name="profile-choice"]'),e=>e.value);
      document.getElementById('profile-all').checked=true;
      updateProfilePath();doExport();
      window.qa={choices,sent:window.sent,text:document.body.innerText};
    JS
    assert_equal %w[exact visual all], result.fetch('choices')
    assert_equal 'all', result.dig('sent', 'profile')
    assert_equal '/tmp/model', result.dig('sent', 'output_path')
    assert_include result.fetch('text'), 'dua profil'
    assert_not_include result.fetch('text'), 'Research'
  end

  def test_e2_and_e3_dialogs_offer_identical_exact_visual_and_export_all_choices
    { 'e2' => '.json.gz', 'e3' => '.cleanpkg' }.each do |engine, extension|
      config = { engine: engine, title: engine, sha: 'a' * 64, formatVersion: 'test', output_path: "/tmp/model#{extension}" }
      result = inspect_dialog('tools/history/evolution_lineup/lineup_dialog.html', <<~JS)
        setConfig(#{config.to_json});
        document.querySelector('input[name="profile-choice"][value="exact"]').checked=true;
        updateProfilePath();
        document.getElementById('export').click();
        window.qa={profiles:Array.from(document.querySelectorAll('input[name="profile-choice"]'),e=>e.value),sent:window.sent};
      JS
      assert_equal %w[exact visual all], result.fetch('profiles')
      assert_equal 'exact', result.dig('sent', 'profile')
      assert_equal "/tmp/model__#{engine.upcase}__EXACT#{extension}", result.dig('sent', 'output_path')

      all = inspect_dialog('tools/history/evolution_lineup/lineup_dialog.html', <<~JS)
        setConfig(#{config.to_json});
        document.querySelector('input[name="profile-choice"][value="all"]').checked=true;
        updateProfilePath();
        document.getElementById('export').click();
        window.qa={sent:window.sent,text:document.body.innerText};
      JS
      assert_equal 'all', all.dig('sent', 'profile')
      assert_equal '/tmp/model', all.dig('sent', 'output_path')
      assert_include all.fetch('text'), 'Ekspor 2 profil'
      assert_not_include all.fetch('text'), 'Research'
    end
  end
  def test_export_all_completion_reports_two_profiles_for_every_active_format
    %w[json.gz cleanpkg bomc].each do |extension|
      result = inspect_dialog('bom_engine/ui/conversion_dialog.html', <<~JS)
        initializeConversion({job_id:42,sequence:1,state:'capturing',output_path:'/tmp/model.#{extension}'});
        completeConversion({job_id:42,sequence:2,state:'completed',batch_export:true,
          path:'/tmp/results',profiles:{exact:{bytes:2048},visual:{bytes:1024}}});
        window.qa={title:document.getElementById('title').textContent,
          stage:document.getElementById('stage').textContent,
          note:document.getElementById('outcome-note').textContent,
          rows:document.getElementById('result-rows').innerText};
      JS
      assert_equal '2 profil selesai', result.fetch('title')
      assert_equal '2 file tersimpan di folder baru', result.fetch('stage')
      assert_include result.fetch('rows'), 'Exact'
      assert_include result.fetch('rows'), 'Visual'
      assert_not_include result.fetch('rows'), 'Research'
      assert_not_include result.fetch('note'), 'Ketiga'
    end
  end

end
