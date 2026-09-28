require 'minitest/autorun'
require 'tmpdir'
require_relative '../bomc_extension'
require_relative '../bomc_jpeg_color_map'

class ExperimentalJcmExportTest < Minitest::Test
  def graph
    base=[10,20,30,255,40,50,60,255].pack('C*');target=[11,22,33,255,44,55,66,255].pack('C*')
    jpeg=[255,216,255,192,0,17,8,0,1,0,2,3,1,17,0,2,17,0,3,17,0,255,218,0,12,3,1,0,2,0,3,0,0,63,0,1,255,217].pack('C*')
    bytes=BOMEngine::BOMCJpegColorMap.encode(jpeg:jpeg,base_rgba:base,target_rgba:target,width:2,height:1)
    evidence={policy_revision:'exact-jcm-1',selected: :jpeg_color_map_candidate,profile: :exact,alpha_preserved:true,
      selected_sha256:Digest::SHA256.hexdigest(bytes),base_pixel_sha256:Digest::SHA256.hexdigest(base),output_pixel_sha256:Digest::SHA256.hexdigest(target),normalized_jpeg_sha256:Digest::SHA256.hexdigest(jpeg),
      required_loader:'bomc-next-jcm-v1',quality:{compatible:true,mean_squared_error:0.0,max_channel_error:0,alpha_preserved:true}}
    {materials:[{id:'m',texture:{bytes:bytes,filename:'texture.jcm',image_width_px:2,image_height_px:1,encoding_evidence:evidence}}],definitions:[{id:'d',kind:'root',node_ids:[]}],nodes:[{id:'root',kind:'root',definition_id:'d',transform_id:0}],transforms:[BOMEngine::BOMC::ModelAdapter::IDENTITY],meshes:[],tags:[]}
  end
  def source_info_for(output_path, bytes)
    path=File.join(File.dirname(output_path),"source-#{bytes}.skp")
    File.binwrite(path,'S'*bytes)
    BOMEngine::BOMCSizeGate.source_info(path)
  end
  def publish(path,source_bytes:1_000_000,profile: :exact)
    BOMEngine::BOMCExtension.publish_graph(path,graph,profile:profile,source_info:source_info_for(path,source_bytes),allow_jpeg_color_map:true)
  end
  def test_explicit_exact_opt_in_validates_and_publishes_smaller_candidate
    Dir.mktmpdir do |dir|
      file=File.join(dir,'candidate.bomc')
      result=begin publish(file);rescue ArgumentError=>e;flunk "Experimental export entry missing: #{e.message}";end
      assert_equal true,result[:published]
      assert_equal File.size(file),result[:bytes]
      assert_equal Digest::SHA256.file(File.join(dir,'source-1000000.skp')).hexdigest,result[:source_skp_sha256]
      assert_equal :under_source,result[:size_target]
      assert_equal 'bomc-next-jcm-v1',result[:required_loader]
      assert BOMEngine::BOMCDecoder.decode(File.binread(file),allow_jpeg_color_map:true)[:textures].any?
      assert_raises(RuntimeError) { BOMEngine::BOMCDecoder.decode(File.binread(file)) }
    end
  end
  def test_default_and_wrong_profile_cannot_silently_use_experimental_codec
    Dir.mktmpdir do |dir|
      file=File.join(dir,'candidate.bomc');File.binwrite(file,'keep')
      assert_raises(RuntimeError) { BOMEngine::BOMCExtension.publish_graph(file,graph,profile: :exact) }
      assert_raises(ArgumentError) { publish(file,profile: :visual) }
      assert_equal 'keep',File.binread(file)
    end
  end
  def test_over_source_budget_and_tampered_evidence_preserve_destination
    Dir.mktmpdir do |dir|
      file=File.join(dir,'candidate.bomc');File.binwrite(file,'keep')
      assert_raises(BOMEngine::BOMCSizeGate::TargetNotMet) { publish(file,source_bytes:1) }
      bad=graph;bad[:materials][0][:texture][:encoding_evidence][:selected_sha256]='0'*64
      assert_raises(BOMEngine::BOMCValidator::ProfileValidationError) do
        BOMEngine::BOMCExtension.publish_graph(file,bad,profile: :exact,source_info:source_info_for(file,1_000_000),allow_jpeg_color_map:true)
      end
      assert_equal 'keep',File.binread(file)
      assert_empty Dir.glob(File.join(dir,'*.part'))
    end
  end

  def test_publication_rechecks_source_hash_and_size_before_atomic_replace
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source.skp')
      output = File.join(dir, 'candidate.bomc')
      File.binwrite(source, 'saved source bytes')
      source_info = BOMEngine::BOMCSizeGate.source_info(source)
      File.binwrite(output, 'keep')
      File.binwrite(source, 'changed after candidate was compiled')

      error = assert_raises(ArgumentError) do
        BOMEngine::BOMCExtension.publish_validated(
          candidate: 'valid-looking bytes', report: { passed: true }, output_path: output, source_info: source_info
        )
      end
      assert_match(/source changed/i, error.message)
      assert_equal 'keep', File.binread(output)
      assert_empty Dir.glob(File.join(dir, '*.part'))
    end
  end
  def test_experimental_export_requires_real_source_size_and_saved_runtime_model
    Dir.mktmpdir do |dir|
      file=File.join(dir,'candidate.bomc')
      assert_raises(ArgumentError) { BOMEngine::BOMCExtension.publish_graph(file,graph,profile: :exact,allow_jpeg_color_map:true) }
      model=Object.new
      model.define_singleton_method(:modified?) { true }
      error=assert_raises(ArgumentError) { BOMEngine::BOMCExtension.export(model,output_path:file,profile: :exact,allow_jpeg_color_map:true) }
      assert_match(/saved|unsaved/,error.message)
      refute File.exist?(file)
    end
  end
end
