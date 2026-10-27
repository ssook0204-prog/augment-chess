package io.github.ssook0204prog.augmentchess;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.util.regex.Pattern;

/** 증강 체스 안드로이드 앱: 항상 최신 사이트를 열고, 인터넷이 없으면 앱에 든 오프라인 판을 열어요. */
public class MainActivity extends Activity {
    static final String SITE = "https://ssook0204-prog.github.io/augment-chess/";
    static final String OFFLINE = "file:///android_asset/offline/index.html";
    static final Pattern[] IN_APP = {
        Pattern.compile("^https://ssook0204-prog\\.github\\.io/augment-chess(/.*)?$"),
        Pattern.compile("^https://[a-z0-9-]+\\.supabase\\.co/.*"),
        Pattern.compile("^https://(www\\.|canary\\.|ptb\\.)?discord(app)?\\.com/.*"),
        Pattern.compile("^file:///android_asset/.*")
    };
    static final int PICK = 41;

    WebView web;
    ValueCallback<Uri[]> pending;
    boolean offline = false;

    static boolean inApp(String u) {
        for (Pattern p : IN_APP) if (p.matcher(u).matches()) return true;
        return false;
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        web = new WebView(this);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setSupportMultipleWindows(false);
        s.setUserAgentString(s.getUserAgentString() + " AugmentChessApp/android");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                String u = r.getUrl().toString();
                if (inApp(u)) return false;
                open(u);
                return true;
            }
            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame() && !offline && r.getUrl().toString().startsWith("https://ssook0204-prog.github.io")) {
                    offline = true;
                    v.loadUrl(OFFLINE);
                }
            }
            @Override
            public void onPageStarted(WebView v, String url, Bitmap f) { super.onPageStarted(v, url, f); }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (pending != null) pending.onReceiveValue(null);
                pending = cb;
                try {
                    startActivityForResult(p.createIntent(), PICK);
                } catch (ActivityNotFoundException e) {
                    pending = null;
                    return false;
                }
                return true;
            }
        });
        if (b != null) web.restoreState(b);
        else web.loadUrl(SITE);
    }

    void open(String u) {
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(u))); } catch (Exception ignored) { }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req == PICK && pending != null) {
            pending.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(res, data));
            pending = null;
            return;
        }
        super.onActivityResult(req, res, data);
    }

    @Override
    protected void onSaveInstanceState(Bundle o) { super.onSaveInstanceState(o); web.saveState(o); }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onPause() { super.onPause(); CookieManager.getInstance().flush(); }
}
