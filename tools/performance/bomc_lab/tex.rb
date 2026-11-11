require File.expand_path('../../../bom_engine/bomc_texture_optimizer', __dir__)
Rep = Struct.new(:width,:height,:bits_per_pixel,:row_padding,:data)
W=H=2048
srand(1)
base = Random.bytes(W*H*4); a=base.dup; (3...a.bytesize).step(4){|i| a.setbyte(i,255)}
lossy=a.dup; (0...lossy.bytesize).step(97){|i| lossy.setbyte(i,(lossy.getbyte(i)+3)%256)}
ref=Rep.new(W,H,32,0,a); same=Rep.new(W,H,32,0,a.dup); cand=Rep.new(W,H,32,0,lossy)
T=->(l,&b){t=Process.clock_gettime(Process::CLOCK_MONOTONIC); r=b.call; puts "%-38s %.2fs" % [l,Process.clock_gettime(Process::CLOCK_MONOTONIC)-t]; r}
O=BOMEngine::BOMCTextureOptimizer
T.("opaque? 4MP (pure Ruby loop)"){O.opaque?(ref)}
T.("compare identical 4MP (fast path)"){O.compare(ref,same)}
T.("compare lossy 4MP (numeric path)"){O.compare(ref,cand)}
T.("SHA256 of 16MB pixels"){Digest::SHA256.hexdigest(a)}
# faster opaque check: bignum AND
T.("opaque? via unpack N* + all?"){a.unpack('N*').all?{|v| v&0xff==0xff}}
T.("opaque? via regexp on alpha"){ (a =~ /...[^\xff]/nm).nil? rescue nil }
T.("opaque? via String#unpack1 + bignum"){ m=("\x00\x00\x00\xff".b*(W*H)); (a.unpack1('H*').to_i(16) & m.unpack1('H*').to_i(16)) == m.unpack1('H*').to_i(16) }
