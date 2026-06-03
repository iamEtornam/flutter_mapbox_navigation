package dev.etornam.mapboxnavigation.factory

import android.app.Activity
import android.content.Context
import android.view.LayoutInflater
import dev.etornam.mapboxnavigation.databinding.NavigationActivityBinding
import dev.etornam.mapboxnavigation.models.views.EmbeddedNavigationMapView
import dev.etornam.mapboxnavigation.utilities.PluginUtilities
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class EmbeddedNavigationViewFactory(
    private val messenger: BinaryMessenger,
    private val activity: Activity
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val inflater = LayoutInflater.from(context)
        val binding = NavigationActivityBinding.inflate(inflater)
        val accessToken = PluginUtilities.getResourceFromContext(context, "mapbox_access_token")
        val view = EmbeddedNavigationMapView(
            context,
            activity,
            binding,
            messenger,
            viewId,
            args,
            accessToken
        )

        view.initialize()

        activity.setTheme(androidx.appcompat.R.style.Theme_AppCompat_NoActionBar)

        return view
    }
}
