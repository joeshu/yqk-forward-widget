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
    public void init(Context context, String ext) throws Exception {media=new JSONObject(ext).getString("mediaURL");}
    private JSONObject item(String id,String name) throws Exception {return new JSONObject().put("vod_id",id).put("vod_name",name);}
    private String list(String id,String name) throws Exception {return new JSONObject().put("list",new JSONArray().put(item(id,name))).toString();}
    public String homeContent(boolean filter) throws Exception {
        return new JSONObject().put("class",new JSONArray().put(new JSONObject().put("type_id","movie").put("type_name","测试分类"))).toString();
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
