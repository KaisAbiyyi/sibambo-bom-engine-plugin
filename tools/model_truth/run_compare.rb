# frozen_string_literal: true

# ruby tools/model_truth/run_compare.rb <run_dir>
#
# Exit 0 = PASS, 1 = FAIL, 2 = ERROR. Prints one line: <model_key> <overall> <failing categories>.

require_relative 'canonical'
require_relative 'compare'

module SibamboModelTruthV1
  module RunCompare
    module_function

    def main(argv)
      run_dir = argv[0]
      abort('usage: run_compare.rb <run_dir>') if run_dir.nil? || run_dir.empty?
      abort("no such run directory: #{run_dir}") unless File.directory?(run_dir)

      diff = Compare.run(run_dir: run_dir)
      key = diff[:model_key] || File.basename(File.dirname(File.expand_path(run_dir)))
      failing = diff[:categories].select { |c| c[:verdict] != 'PASS' }.map { |c| c[:category] }
      failing = [diff[:error]] if diff[:overall] == 'ERROR'
      puts "#{key} #{diff[:overall]} #{failing.join(',')}".strip
      { 'PASS' => 0, 'FAIL' => 1 }.fetch(diff[:overall], 2)
    end
  end
end

exit(SibamboModelTruthV1::RunCompare.main(ARGV)) if $PROGRAM_NAME == __FILE__
