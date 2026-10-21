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
      stub = '<script>window.sketchup={onReady(){},browse(){},cancel(){},export(value){window.sent=JSON.parse(value)}};</script>'
      html.sub!('<script>', stub + '<script>')
      html.sub!('</body>', "<script>#{script};document.body.setAttribute('data-qa',encodeURIComponent(JSON.stringify(window.qa)));</script></body>")
      path = File.join(directory, 'dialog.html')
      File.write(path, html)
      driver = File.join(directory, 'inspect.cjs')
      File.write(driver, <<~'JS')
        const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
        (async () => {
          const browser = await chromium.launch({headless:true});
          try {
            const page = await browser.newPage();
            const errors = [];
            page.on('pageerror', error => errors.push(error.message));
            page.on('dialog', async dialog => { errors.push(dialog.message()); await dialog.dismiss(); });
            await page.goto(process.argv[2]);
            await page.waitForFunction(() => document.body.dataset.qa);
            const result = await page.evaluate(() => JSON.parse(decodeURIComponent(document.body.dataset.qa)));
            console.log(JSON.stringify({...result, scriptErrors:errors}));
          } finally { await browser.close(); }
        })().catch(error => { console.error(error); process.exitCode=1; });
      JS
      stdout, stderr, status = Open3.capture3('node', driver, "file://#{path}")
      assert status.success?, stderr.lines.last(3).join
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
      assert_include all.fetch('text'), 'dua profil'
      assert_not_include all.fetch('text'), 'Research'
    end
  end
end
