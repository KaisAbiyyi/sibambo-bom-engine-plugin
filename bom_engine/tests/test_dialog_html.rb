# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'cgi'
require 'uri'
require 'fileutils'

class DialogHtmlTest < Minitest::Test
  CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe'

  def render(name, script, label: nil)
    skip 'Headless Chrome unavailable' unless File.file?(CHROME)
    source = File.read(File.expand_path("../ui/#{name}", __dir__))
    Dir.mktmpdir('bomc-ui-test-') do |folder|
      html = File.join(folder, name)
      FileUtils.cp(File.expand_path('../ui/bomc_theme.css', __dir__), File.join(folder, 'bomc_theme.css'))
      injected = "<script>window.sketchup={ready:function(){},onReady:function(){},export:function(v){window.sent=JSON.parse(v)},start:function(v){window.sent=JSON.parse(v)},cancel:function(){},close:function(){},openFolder:function(){}};#{script};document.body.setAttribute('data-qa',encodeURIComponent(JSON.stringify(window.qa)));</script>"
      File.write(html, source.sub('</body>', "#{injected}</body>"))
      size = name == 'bomc_export_dialog.html' ? '680,795' :
        (name == 'capture_options.html' ? '620,705' : (label == 'capture-complete' ? '620,755' : (label == 'progress-active' ? '620,640' : '620,485')))
      stdout, stderr, status = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
        '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome')}",
        "--window-size=#{size}", '--virtual-time-budget=1000', '--dump-dom', "file:///#{html.tr('\\', '/')}")
      assert status.success?, "Chrome failed: #{stderr.lines.last(4).join}"
      payload = stdout[/<body[^>]*data-qa="([^"]*)"/m, 1]
      refute_nil payload, "UI script did not report state: #{stderr.lines.last(4).join}"
      if label && ENV['BOMC_QA_SCREENSHOT_DIR']
        screenshot = File.join(ENV.fetch('BOMC_QA_SCREENSHOT_DIR'), "#{label}.png")
        _out, err, shot_status = Open3.capture3(CHROME, '--headless=new', '--disable-gpu', '--no-first-run',
          '--no-default-browser-check', "--user-data-dir=#{File.join(folder, 'chrome-shot')}",
          "--window-size=#{size}", "--screenshot=#{screenshot}", "file:///#{html.tr('\\', '/')}")
        assert shot_status.success? && File.file?(screenshot), "Screenshot failed: #{err.lines.last(4).join}"
      end
      JSON.parse(URI.decode_www_form_component(CGI.unescapeHTML(payload)))
    end
  end

  def test_progress_dialog_hides_unknown_counts
    result = render('conversion_dialog.html', "window.qa={text:document.body.innerText,processed:document.getElementById('processed').hidden};")
    refute_includes result['text'], '0 / 0'
    assert result['processed']
  end

  def test_phase_local_progress_never_claims_overall_completion
    result = render('conversion_dialog.html', <<~JS, label: 'progress-active')
      initializeConversion({job_id:31,sequence:1,state:'capturing',output_path:'D:/exports/model.bomc'});
      updateProgress({job_id:31,sequence:2,state:'capturing',phase_id:'textures',stage:'SNAPSHOT_TEXTURES',operation_label:'mtl',unit:'material',processed:159,total:159});
      window.qa={label:document.getElementById('overall-label').textContent,
        counter:document.getElementById('processed').textContent,
        operation:document.getElementById('operation').textContent,
        wholeValue:document.getElementById('track').getAttribute('aria-valuenow'),
        localPercent:document.getElementById('percent').textContent,
        phase:document.querySelector('[data-phase="textures"]').dataset.status,
        lastPhase:document.querySelector('[data-phase="publish"]').dataset.status,
        height:document.documentElement.scrollHeight,viewport:window.innerHeight};
    JS
    assert_includes result['label'], 'belum diketahui'
    assert_nil result['wholeValue']
    assert_includes result['counter'], '159 / 159 material'
    assert_includes result['operation'], 'mtl'
    assert_includes result['localPercent'], 'dari fase'
    assert_equal 'active', result['phase']
    assert_equal 'waiting', result['lastPhase']
    assert_operator result['height'], :<=, result['viewport'], 'active progress layout should fit the expanded dialog'
  end

  def test_impossible_counts_are_diagnostic_and_pass_restarts_are_labeled
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({job_id:32,sequence:1,state:'capturing',output_path:'D:/exports/model.bomc'});
      updateProgress({job_id:32,sequence:2,state:'capturing',phase_id:'textures',stage:'SNAPSHOT_TEXTURES',processed:142,total:159});
      updateProgress({job_id:32,sequence:3,state:'capturing',phase_id:'textures',stage:'SNAPSHOT_TEXTURES',processed:39,total:159});
      const restarted=document.getElementById('processed').textContent;
      updateProgress({job_id:32,sequence:4,state:'capturing',phase_id:'capture',stage:'SNAPSHOT_ENTITIES',processed:835632,total:198});
      window.qa={restarted:restarted,warning:document.getElementById('counter-warning').textContent,
        processedHidden:document.getElementById('processed').hidden,
        globalPercent:document.getElementById('track').getAttribute('aria-valuenow')};
    JS
    assert_includes result['restarted'], 'pass 2'
    assert_includes result['warning'], 'belum terukur'
    assert result['processedHidden']
    assert_nil result['globalPercent']
  end

  def test_texture_capture_returns_to_entity_capture_without_rewinding_completed_texture
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({job_id:33,sequence:1,state:'capturing',output_path:'D:/exports/model.bomc'});
      updateProgress({job_id:33,sequence:2,state:'capturing',phase_id:'textures',stage:'SNAPSHOT_TEXTURES',processed:7,total:7});
      updateProgress({job_id:33,sequence:3,state:'capturing',phase_id:'capture',stage:'SNAPSHOT_ENTITIES',processed:10,total:100});
      window.qa={capture:document.querySelector('[data-phase="capture"]').dataset.status,
        textures:document.querySelector('[data-phase="textures"]').dataset.status,
        compile:document.querySelector('[data-phase="compile"]').dataset.status};
    JS
    assert_equal 'active', result['capture']
    assert_equal 'completed', result['textures']
    assert_equal 'waiting', result['compile']
  end

  def test_progress_dialog_rejects_stale_and_out_of_order_events
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({job_id:11,sequence:1,state:'capturing',output_path:'D:/one.bomc'});
      updateProgress({job_id:11,sequence:3,state:'compiling',stage:'new stage',processed:3,total:10});
      updateProgress({job_id:11,sequence:2,state:'capturing',stage:'old stage',processed:2,total:10});
      initializeConversion({job_id:12,sequence:1,state:'capturing',output_path:'D:/two.bomc'});
      updateProgress({job_id:12,sequence:2,state:'validating',stage:'current generation',processed:1,total:1});
      completeConversion({job_id:11,sequence:99,state:'completed',path:'D:/one.bomc'});
      window.qa={stage:document.getElementById('stage').textContent,path:document.getElementById('path').textContent,bodyClass:document.body.className};
    JS
    assert_includes result['stage'], 'current generation'
    assert_equal 'D:/two.bomc', result['path']
    refute_equal 'done', result['bodyClass']
  end

  def test_progress_dialog_heartbeat_distinguishes_atomic_wait_from_long_stall
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({job_id:21,sequence:1,state:'compiling',output_path:'D:/work.bomc'});
      refreshBackendHeartbeat(performance.now()+2000);
      const atomicText=document.getElementById('backend-state').textContent;
      refreshBackendHeartbeat(performance.now()+11000);
      window.qa={atomicText:atomicText,stalledText:document.getElementById('backend-state').textContent};
    JS
    assert_includes result['atomicText'], 'host/atomic call'
    assert_includes result['stalledText'], 'Belum ada checkpoint'
  end

  def test_capture_completion_reports_three_files_and_pending_audit
    result = render('conversion_dialog.html', <<~JS, label: 'capture-complete')
      initializeConversion({title:'Preview',output_path:'D:/results/capture-1',batch_size:8192,capture:true});
      completeConversion({capture:true,path:'D:/results/capture-1',source_bytes:440016,
        profiles:{visual:{bytes:155683},research:{bytes:165554},exact:{bytes:219674}},elapsed_seconds:26.5});
      window.qa={text:document.body.innerText,processed:document.getElementById('processed').hidden,
        height:document.documentElement.scrollHeight,viewport:window.innerHeight};
    JS
    assert_includes result['text'], 'Visual'
    assert_includes result['text'], 'Research'
    assert_includes result['text'], 'Exact'
    assert_includes result['text'], 'belum'
    refute_includes result['text'], '0 objek'
    refute_includes result['text'], 'File siap digunakan oleh model-eval'
    assert_operator result['height'], :<=, result['viewport'], 'completed capture must fit without a scrollbar'
  end

  def test_export_dialog_exact_and_manual_batch_are_explicit
    result = render('bomc_export_dialog.html', <<~JS, label: 'export-exact')
      setDefaultPath('D:/exports/house.skp');
      document.getElementById('profile-exact').checked=true;updateProfilePath();
      document.querySelector('input[name="batch-mode"][value="manual"]').checked=true;refreshBatchMode();
      document.getElementById('batch-size').value='8192';doExport();
      window.qa={sent:window.sent,text:document.body.innerText};
    JS
    assert_equal 'exact', result.dig('sent', 'profile')
    assert_equal 'manual', result.dig('sent', 'batch_mode')
    assert_equal 8192, result.dig('sent', 'batch_size')
    assert_equal 'D:/exports/house__SIBAMBO-BOMC-v1.2.0__EXACT.bomc', result.dig('sent', 'output_path')
    assert_includes result['text'], 'tidak menjamin'
  end

  def test_export_dialog_all_is_a_fourth_choice_with_one_base_path
    result = render('bomc_export_dialog.html', <<~JS)
      setDefaultPath('D:/exports/house.skp');
      document.getElementById('profile-all').checked=true;updateProfilePath();doExport();
      window.qa={sent:window.sent,text:document.body.innerText,
        choices:document.querySelectorAll('input[name="profile-choice"]').length,
        height:document.documentElement.scrollHeight,viewport:window.innerHeight};
    JS
    assert_equal 4, result['choices']
    assert_equal 'all', result.dig('sent', 'profile')
    assert_equal 'D:/exports/house', result.dig('sent', 'output_path')
    assert_includes result['text'], 'folder'
    refute_includes result['text'], 'adaptif sampai 2048'
    assert_operator result['height'], :<=, result['viewport'], 'four choices and action must fit the export dialog'
  end

  def test_all_completion_lists_three_files_without_claiming_certification
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({output_path:'D:/exports/house',batch_export:true});
      completeConversion({batch_export:true,path:'D:/exports/house__ALL-123',
        profiles:{visual:{bytes:10},research:{bytes:20},exact:{bytes:30}},elapsed_seconds:15});
      window.qa={text:document.body.innerText};
    JS
    %w[Visual Research Exact].each { |name| assert_includes result['text'], name }
    assert_includes result['text'], 'belum'
    refute_includes result['text'], 'Satu file BOMC tersimpan'
  end

  def test_all_preflight_failure_does_not_claim_partial_files_exist
    result = render('conversion_dialog.html', <<~JS)
      initializeConversion({output_path:'D:/exports/house',batch_export:true});
      failConversion({batch_export:true,partial_result:false,path:'D:/exports/house',message:'Simpan model dahulu'});
      window.qa={text:document.body.innerText,openVisible:document.getElementById('open').style.display};
    JS
    refute_includes result['text'], 'export-status.json'
    refute_includes result['text'], 'File profil sebelumnya tetap ada'
    assert_equal 'none', result['openVisible']
  end

  def test_preview_options_keep_three_profile_capture_and_send_manual_batch
    result = render('capture_options.html', <<~JS, label: 'capture-options')
      initializeCaptureOptions({source_name:'house2.skp',build_sha:'123456789abc'});
      document.querySelector('input[name="batch-mode"][value="manual"]').checked=true;refreshBatchMode();
      document.getElementById('batch-size').value='8192';startCapture();
      window.qa={sent:window.sent,text:document.body.innerText};
    JS
    assert_equal 'manual', result.dig('sent', 'batch_mode')
    assert_equal 8192, result.dig('sent', 'batch_size')
    assert_includes result['text'], 'Exact'
    assert_includes result['text'], 'belum'
  end
end
