import java.nio.file.*;
import org.json.*;
import tvbox.runtime.InProcessHost;
/** Runs actual DEX conversion and plugin dispatch, without network source dependencies. */
public final class HostFixtureTest {
    static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] args) throws Exception {
        Path root=Files.createTempDirectory("cctv-dex-fixture");
        JSONObject input=new JSONObject().put("session","fixture").put("runtime","fixture-archive").put("runtimeCache",root.resolve("runtime").toString())
            .put("jar",args[0]).put("cache",root.resolve("session").toString()).put("conversionCache",root.resolve("converted").toString())
            .put("api","csp_CCTVFixture").put("key","fixture").put("ext",new JSONObject().put("mediaURL","http://127.0.0.1:1234/video.mp4").toString());
        JSONObject[] params={new JSONObject(),new JSONObject().put("t","movie").put("pg","2").put("filters","{\"area\":\"测试地区\"}"),
            new JSONObject().put("wd","中文😀+&").put("pg","2"),new JSONObject().put("ids","fixture"),
            new JSONObject().put("play","opaque+id%26signed").put("flag","fixture").put("detailID","fixture")};
        for(int i=0;i<params.length;i++){
            input.put("request","request-"+i).put("deadline",30).put("params",params[i]);
            JSONObject envelope=new JSONObject(InProcessHost.request(input.toString()));
            check(!envelope.has("error"),"request "+i+" failed: "+envelope);
            JSONObject answer=new JSONObject(envelope.getString("result"));
            if(i==0)check(answer.getJSONArray("class").length()==1&&answer.getJSONArray("list").length()==1&&answer.getJSONArray("runtime_checks").length()==7,"home/runtime compatibility");
            if(i==1)check(answer.getJSONArray("list").getJSONObject(0).getString("vod_name").equals("测试地区"),"filters");
            if(i==2)check(answer.getJSONArray("list").getJSONObject(0).getString("vod_name").equals("中文😀+&"),"Unicode");
            if(i==3)check(answer.getJSONArray("list").getJSONObject(0).getString("vod_play_url").endsWith("opaque+id%26signed"),"opaque ID");
            if(i==4)check(answer.getString("url").endsWith("/video.mp4")&&answer.getJSONObject("header").getString("X-Media-Fixture").equals("media-only"),"playback");
        }
        System.out.println("DEX fixture home/category/search/detail/play passed");
        System.exit(0);
    }
}
