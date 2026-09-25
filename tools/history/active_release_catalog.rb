# frozen_string_literal: true

require 'json'

module EvolutionActiveCatalog
  DEFAULT_PATH = File.expand_path('../../history/active-releases.json', __dir__)

  ALLOWED_RELEASE_IDS = %w[
    scene-resilient-a158b75
    scene-fidelity-a138fe6
    baseline-8082541
    next-from-8082541
  ].freeze

  ALLOWED_LOADER_IDS = %w[
    scene-resilient-v1
    scene-fidelity-v1
    bomc-8082541-v1
    bomc-next-v1
  ].freeze

  ALLOWED_STATES = %w[uncertified ready development incomplete].freeze
  ALLOWED_ENTRY_KINDS = %w[legacy-scene bomc-three-profile].freeze
  ALLOWED_PROFILES = %w[visual research exact].freeze
  E4_BASE_PRODUCER_SHA = '8082541d852cd68b9874231e41c6b9c967c74d26'.freeze

  HEX_40_RE = /\A[0-9a-f]{40}\z/.freeze
  HEX_64_RE = /\A[0-9a-f]{64}\z/.freeze

  def self.load(path: nil, verify_certifications: true, root_dir: nil)
    catalog_path = path ? File.expand_path(path) : DEFAULT_PATH
    raise "Active releases catalog not found: #{catalog_path}" unless File.file?(catalog_path)

    data = JSON.parse(File.read(catalog_path))
    records = data.is_a?(Array) ? data : data['releases']
    raise 'Invalid catalog format: expected array of releases' unless records.is_a?(Array)

    effective_root = root_dir || File.dirname(File.dirname(catalog_path))
    validate!(records, verify_certifications: verify_certifications, root_dir: effective_root)
    records
  end

  def self.packagable(records)
    records.select do |record|
      record['state'] == 'ready' && !record['producerSha'].nil?
    end
  end

  def self.buildable(records)
    records.select do |record|
      !record['producerSha'].nil?
    end
  end

  def self.find_candidate(records, candidate_id)
    records.find do |record|
      record['id'] == candidate_id && !record['producerSha'].nil?
    end
  end

  def self.resolve_certification(record, root_dir: nil)
    root = root_dir || File.expand_path('../..', __dir__)
    cert_id = record['certificationId']
    return nil if cert_id.nil? || cert_id.to_s.strip.empty?

    candidates = []
    if record['certificationPath']
      candidates << File.expand_path(record['certificationPath'], root)
    end
    candidates << File.join(root, 'history', 'certifications', "#{record['id']}.json")
    candidates << File.join(root, 'history', 'certifications', "#{cert_id}.json")
    candidates << File.join(root, 'artifacts', 'evolution-certification', record['id'], 'certification.json')
    candidates << File.join(root, '..', 'scratch', 't7-worktrees-20260908', 'consumer', 'artifacts', 'evolution-certification', 't7-20260908', record['id'], 'certification.json')
    candidates << File.join(root, '..', 'scratch', 't0-worktrees-20260907', 'consumer', 'artifacts', 'evolution-certification', record['id'], 'certification.json')

    candidates.each do |cand|
      return cand if File.file?(cand)
    end
    nil
  end

  def self.verify_certification!(record, root_dir: nil)
    cert_path = resolve_certification(record, root_dir: root_dir)
    unless cert_path
      raise "ready release #{record['id']} references certificationId #{record['certificationId'].inspect} but no certification artifact could be resolved"
    end

    begin
      cert = JSON.parse(File.read(cert_path))
    rescue StandardError => e
      raise "ready release #{record['id']} certification artifact #{cert_path} is invalid JSON: #{e.message}"
    end

    schema_version = cert['schemaVersion']
    unless schema_version.to_s =~ /\A(t7|sibambo)-evolution-certification-v\d+\z/
      raise "ready release #{record['id']} has invalid certification schemaVersion: #{schema_version.inspect}"
    end

    if cert['certificationId'] != record['certificationId']
      raise "ready release #{record['id']} certificationId mismatch: catalog has #{record['certificationId'].inspect}, artifact has #{cert['certificationId'].inspect}"
    end

    if cert['releaseId'] != record['id']
      raise "ready release #{record['id']} releaseId mismatch: catalog has #{record['id'].inspect}, artifact has #{cert['releaseId'].inspect}"
    end

    if cert['ready'] != true
      raise "ready release #{record['id']} has ready=false in certification artifact (status: #{cert['status']})"
    end

    if cert['status'] != 'ready'
      raise "ready release #{record['id']} has status=#{cert['status'].inspect} in certification artifact; expected 'ready'"
    end

    if cert['provisional'] == true
      raise "ready release #{record['id']} certification is provisional (dirty consumer checkout) and cannot be promoted"
    end

    tuple = cert['tuple'] || {}
    %w[producerSha consumerSha packageSha256].each do |key|
      unless tuple.is_a?(Hash) && tuple[key].is_a?(String) && !tuple[key].empty?
        raise "ready release #{record['id']} certification tuple missing #{key}"
      end
    end
    if tuple['producerSha'] && tuple['producerSha'] != record['producerSha']
      raise "ready release #{record['id']} producerSha mismatch: catalog #{record['producerSha']}, cert #{tuple['producerSha']}"
    end
    if tuple['consumerSha'] && tuple['consumerSha'] != record['consumerSha']
      raise "ready release #{record['id']} consumerSha mismatch: catalog #{record['consumerSha']}, cert #{tuple['consumerSha']}"
    end
    if tuple['packageSha256'] && tuple['packageSha256'] != record['packageSha256']
      raise "ready release #{record['id']} packageSha256 mismatch: catalog #{record['packageSha256']}, cert #{tuple['packageSha256']}"
    end

    cert
  end

  def self.validate!(records, verify_certifications: true, root_dir: nil)
    raise 'expected four slots' unless records.length == 4

    # 1. Unique IDs
    ids = records.map { |r| r['id'] }
    raise 'duplicate release IDs' unless ids.uniq.length == 4

    ids.each do |id|
      raise "unknown release ID: #{id}" unless ALLOWED_RELEASE_IDS.include?(id)
    end

    # 2. Unique orders 1..4
    orders = records.map { |r| r['order'] }
    raise 'duplicate release orders' unless orders.uniq.length == 4
    raise 'orders must be 1, 2, 3, 4' unless orders.sort == [1, 2, 3, 4]

    # 3. Ancestry check for slot 4 (order 4)
    next_release = records.find { |r| r['order'] == 4 }
    raise 'slot 4 missing' unless next_release
    unless next_release['baseProducerSha'] == E4_BASE_PRODUCER_SHA
      raise "wrong E4 ancestry: expected #{E4_BASE_PRODUCER_SHA}, got #{next_release['baseProducerSha']}"
    end

    records.each do |record|
      state = record['state']
      raise "invalid state: #{state}" unless ALLOWED_STATES.include?(state)

      entry_kind = record['entryKind']
      raise "unknown entryKind: #{entry_kind}" unless ALLOWED_ENTRY_KINDS.include?(entry_kind)

      loader_id = record['loaderId']
      raise "unknown loaderId: #{loader_id}" unless ALLOWED_LOADER_IDS.include?(loader_id)

      profiles = record['profiles']
      raise 'profiles must be non-empty array' unless profiles.is_a?(Array) && !profiles.empty?
      profiles.each do |p|
        raise "unknown profile: #{p}" unless ALLOWED_PROFILES.include?(p)
      end

      # Validate SHAs
      base_sha = record['baseProducerSha']
      raise "invalid baseProducerSha: #{base_sha}" unless base_sha =~ HEX_40_RE

      prod_sha = record['producerSha']
      if prod_sha
        raise "invalid producerSha: #{prod_sha}" unless prod_sha =~ HEX_40_RE
      elsif state != 'development'
        raise "producerSha cannot be null when state is #{state}"
      end

      consumer_sha = record['consumerSha']
      if consumer_sha
        raise "invalid consumerSha: #{consumer_sha}" unless consumer_sha =~ HEX_40_RE
      end

      pkg_sha = record['packageSha256']
      if pkg_sha
        raise "invalid packageSha256: #{pkg_sha}" unless pkg_sha =~ HEX_64_RE
      end

      tree_sha = record['snapshotTreeSha256']
      if tree_sha
        raise "invalid snapshotTreeSha256: #{tree_sha}" unless tree_sha =~ HEX_64_RE
      end

      # Ready state invariant: all hashes and certification must be present and verified
      if state == 'ready'
        raise "ready release #{record['id']} must have producerSha" unless prod_sha
        raise "ready release #{record['id']} must have consumerSha" unless consumer_sha
        raise "ready release #{record['id']} must have packageSha256" unless pkg_sha
        raise "ready release #{record['id']} must have certificationId" if record['certificationId'].to_s.strip.empty?
        verify_certification!(record, root_dir: root_dir) if verify_certifications
      end
    end
  end
end
