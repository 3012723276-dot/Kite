package dev.yuxinqiao.kumone

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import dev.yuxinqiao.kumone.ui.KiteApp
import dev.yuxinqiao.kumone.ui.UiTokens

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme(
                    primary = UiTokens.Accent,
                    background = UiTokens.Background,
                    surface = UiTokens.Surface,
                    surfaceVariant = UiTokens.SurfaceElevated,
                    onBackground = UiTokens.TextPrimary,
                    onSurface = UiTokens.TextPrimary,
                    onSurfaceVariant = UiTokens.TextSecondary,
                    error = UiTokens.Error,
                ),
            ) {
                KiteApp()
            }
        }
    }
}
