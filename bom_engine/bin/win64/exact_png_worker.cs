using System;
using System.IO;
using System.IO.Compression;

// Pure byte work only. No SketchUp APIs, model handles, floating-point image
// conversion, palette reduction, premultiplication or lossy representation.
public static class SibamboExactPngWorker {
  static int Paeth(int a,int b,int c) {
    int p=a+b-c,pa=Math.Abs(p-a),pb=Math.Abs(p-b),pc=Math.Abs(p-c);
    return pa<=pb && pa<=pc ? a : (pb<=pc ? b : c);
  }
  public static void Run(string mode,string input,string output,int w,int h,int channels,int padding,bool bgr) {
    if(w<=0 || h<=0 || (long)w*h>32000000 || (channels!=3 && channels!=4) || padding<0) throw new ArgumentException("Invalid dimensions/layout");
    byte[] bytes=File.ReadAllBytes(input);
    if(mode=="filter") {
      int stride=checked(w*channels),expected=checked(h*(stride+1));
      if(bytes.Length!=expected) throw new ArgumentException("Invalid filtered byte count");
      byte[] result=new byte[expected],previous=new byte[stride];
      for(int y=0;y<h;y++) {
        int at=y*(stride+1),filter=bytes[at];
        if(filter>4) throw new ArgumentException("Invalid PNG filter");
        byte[] row=new byte[stride];
        for(int x=0;x<stride;x++) {
          int left=x>=channels ? row[x-channels] : 0,up=previous[x],ul=x>=channels ? previous[x-channels] : 0;
          int predictor=filter==0 ? 0 : filter==1 ? left : filter==2 ? up : filter==3 ? (left+up)/2 : Paeth(left,up,ul);
          row[x]=(byte)((bytes[at+1+x]+predictor)&255);
        }
        byte[][] candidates=new byte[5][];for(int i=0;i<5;i++) candidates[i]=new byte[stride];
        long[] scores=new long[5];
        for(int x=0;x<stride;x++) {
          int value=row[x],left=x>=channels ? row[x-channels] : 0,up=previous[x],ul=x>=channels ? previous[x-channels] : 0;
          int[] v={value,(value-left)&255,(value-up)&255,(value-((left+up)/2))&255,(value-Paeth(left,up,ul))&255};
          for(int i=0;i<5;i++) {candidates[i][x]=(byte)v[i];scores[i]+=v[i]<128 ? v[i] : 256-v[i];}
        }
        int best=0;for(int i=1;i<5;i++) if(scores[i]<scores[best]) best=i;
        result[at]=(byte)best;Buffer.BlockCopy(candidates[best],0,result,at+1,stride);previous=row;
      }
      File.WriteAllBytes(output,result);
    } else if(mode=="frame") {
      int rowBytes=checked(w*channels),stride=checked(rowBytes+padding);
      if(bytes.Length!=checked(stride*h)) throw new ArgumentException("Invalid frame byte count");
      byte[] raw=new byte[checked(h*(rowBytes+1))];
      for(int y=0;y<h;y++) {
        int src=y*stride,dst=y*(rowBytes+1)+1;
        for(int x=0;x<w;x++) {
          raw[dst]=bytes[src+(bgr?2:0)];raw[dst+1]=bytes[src+1];raw[dst+2]=bytes[src+(bgr?0:2)];
          if(channels==4) raw[dst+3]=bytes[src+3];src+=channels;dst+=channels;
        }
      }
      WritePng(output,w,h,channels,raw);
    } else throw new ArgumentException("Unknown worker mode");
  }
  static void U32(Stream output,uint value) {
    output.WriteByte((byte)(value>>24));output.WriteByte((byte)(value>>16));output.WriteByte((byte)(value>>8));output.WriteByte((byte)value);
  }
  static uint Crc(byte[] type,byte[] data) {
    uint c=0xffffffff;foreach(byte b in type) {c^=b;for(int i=0;i<8;i++) c=(c&1)!=0 ? (c>>1)^0xedb88320 : c>>1;}
    foreach(byte b in data) {c^=b;for(int i=0;i<8;i++) c=(c&1)!=0 ? (c>>1)^0xedb88320 : c>>1;}return c^0xffffffff;
  }
  static uint Adler(byte[] bytes) {
    uint a=1,b=0;int at=0;
    while(at<bytes.Length) {int end=Math.Min(at+5552,bytes.Length);for(;at<end;at++){a+=bytes[at];b+=a;}a%=65521;b%=65521;}return (b<<16)|a;
  }
  static void Chunk(Stream output,string name,byte[] data) {
    byte[] type=System.Text.Encoding.ASCII.GetBytes(name);U32(output,(uint)data.Length);output.Write(type,0,4);output.Write(data,0,data.Length);U32(output,Crc(type,data));
  }
  static void WritePng(string path,int w,int h,int channels,byte[] raw) {
    byte[] compressed;
    using(var data=new MemoryStream()) {
      data.WriteByte(0x78);data.WriteByte(0x9c);
      using(var deflate=new DeflateStream(data,CompressionLevel.Optimal,true)) deflate.Write(raw,0,raw.Length);
      U32(data,Adler(raw));compressed=data.ToArray();
    }
    using(var file=new FileStream(path,FileMode.CreateNew,FileAccess.Write)) {
      byte[] signature={137,80,78,71,13,10,26,10};file.Write(signature,0,8);
      using(var header=new MemoryStream()) {U32(header,(uint)w);U32(header,(uint)h);header.WriteByte(8);header.WriteByte(channels==4?(byte)6:(byte)2);header.WriteByte(0);header.WriteByte(0);header.WriteByte(0);Chunk(file,"IHDR",header.ToArray());}
      Chunk(file,"IDAT",compressed);Chunk(file,"IEND",new byte[0]);
    }
  }
}
