// Controlled, local-only CatVod fixture. No external sites or credentials.
package com.github.catvod.spider;
import android.content.Context;
import com.github.catvod.crawler.Spider;
import java.util.HashMap;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;
public final class CCTVFixture extends Spider {
    private String media;
    private final JSONArray runtimeChecks=new JSONArray();
    private void require(boolean condition,String message) {if(!condition)throw new IllegalStateException(message);}
    public void init(Context context, String ext) throws Exception {
        media=new JSONObject(ext).getString("mediaURL");
        for(String encoding:new String[]{"GBK","GB18030","Big5"}) {
            java.nio.charset.Charset charset=java.nio.charset.Charset.forName(encoding);
            require(new String("中文".getBytes(charset),charset).equals("中文"),encoding);
        }
        runtimeChecks.put("Chinese charsets");
        java.security.Provider bc=new org.bouncycastle.jce.provider.BouncyCastleProvider();
        byte[] data="中文 crypto".getBytes("UTF-8"),key=new byte[16],nonce=new byte[12];
        javax.crypto.Cipher cipher=javax.crypto.Cipher.getInstance("AES/GCM/NoPadding",bc);
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE,new javax.crypto.spec.SecretKeySpec(key,"AES"),new javax.crypto.spec.GCMParameterSpec(128,nonce));
        byte[] encrypted=cipher.doFinal(data);
        cipher.init(javax.crypto.Cipher.DECRYPT_MODE,new javax.crypto.spec.SecretKeySpec(key,"AES"),new javax.crypto.spec.GCMParameterSpec(128,nonce));
        require(java.util.Arrays.equals(data,cipher.doFinal(encrypted)),"BC AES/GCM");
        require(java.security.MessageDigest.getInstance("SHA-256",bc).digest(data).length==32,"BC SHA-256");
        runtimeChecks.put("Bouncy Castle crypto");
        require(javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(new java.io.ByteArrayInputStream("<root>中文</root>".getBytes("UTF-8"))).getDocumentElement().getTextContent().equals("中文"),"XML");
        require(org.jsoup.Jsoup.parse("<p>中文</p>").text().equals("中文"),"HTML");
        require(new com.google.gson.Gson().toJson("中文").contains("中文"),"Gson");
        require(com.alibaba.fastjson.JSON.parseObject("{\"ok\":true}").getBooleanValue("ok"),"Fastjson");
        runtimeChecks.put("XML HTML JSON");
        java.nio.file.Path directory=java.nio.file.Files.createTempDirectory("cctv-zipfs"),archive=directory.resolve("fixture.zip");
        try {
            java.net.URI uri=java.net.URI.create("jar:"+archive.toUri());
            try(java.nio.file.FileSystem fs=java.nio.file.FileSystems.newFileSystem(uri,java.util.Collections.singletonMap("create","true"))) {
                java.nio.file.Path entry=fs.getPath("/中文.txt");java.nio.file.Files.write(entry,data);
                require(java.util.Arrays.equals(data,java.nio.file.Files.readAllBytes(entry)),"ZIP filesystem");
            }
        } finally {java.nio.file.Files.deleteIfExists(archive);java.nio.file.Files.deleteIfExists(directory);}
        runtimeChecks.put("ZIP filesystem");
        require(java.lang.management.ManagementFactory.getThreadMXBean()!=null,"Management");
        java.util.logging.Logger.getLogger("cctv.fixture");
        require(new javax.naming.CompositeName("source/fixture").size()==2,"Naming");
        require(javax.security.sasl.Sasl.getSaslClientFactories()!=null,"SASL");
        runtimeChecks.put("Management logging naming SASL");
        for(String name:new String[]{"okhttp3.OkHttpClient","com.google.common.collect.ImmutableList","com.hierynomus.smbj.SMBClient","com.google.zxing.MultiFormatWriter","com.github.unidbg.AndroidEmulator","android.app.Activity"})Class.forName(name,false,getClass().getClassLoader());
        runtimeChecks.put("Reflective dependency loading");
        try(java.io.InputStream asset=context.getAssets().open("compatibility.txt")) {
            java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream();byte[] buffer=new byte[128];int count;
            while((count=asset.read(buffer))!=-1)out.write(buffer,0,count);
            require(new String(out.toByteArray(),"UTF-8").equals("plugin asset preserved"),"Plugin assets");
        }
        runtimeChecks.put("Plugin assets");
    }
    private JSONObject item(String id,String name) throws Exception {return new JSONObject().put("vod_id",id).put("vod_name",name);}
    private String list(String id,String name) throws Exception {return new JSONObject().put("list",new JSONArray().put(item(id,name))).toString();}
    public String homeContent(boolean filter) throws Exception {
        return new JSONObject().put("runtime_checks",runtimeChecks).put("class",new JSONArray().put(new JSONObject().put("type_id","movie").put("type_name","测试分类"))).toString();
    }
    public String homeVideoContent() throws Exception {return list("fixture","中文😀影片");}
    public String categoryContent(String type,String page,boolean filter,HashMap<String,String> filters) throws Exception {return new JSONObject(list(type,filters.get("area"))).put("page",page).put("pagecount",3).toString();}
    public String searchContent(String query,boolean quick,String page) throws Exception {return list("search",query);}
    public String detailContent(List<String> ids) throws Exception {return new JSONObject().put("list",new JSONArray().put(item(ids.get(0),"详情").put("vod_play_from","fixture").put("vod_play_url","第1集$opaque+id%26signed"))).toString();}
    public String playerContent(String flag,String id,List<String> flags) throws Exception {
        if(!id.equals("opaque+id%26signed"))throw new IllegalArgumentException("Episode identity changed");
        return new JSONObject().put("url",media).put("parse",0).put("header",new JSONObject().put("X-Media-Fixture","media-only")).toString();
    }
}
