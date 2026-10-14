package chat.simplex.common.helpers

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import chat.simplex.common.model.SharedPreference
import chat.simplex.common.platform.androidAppContext
import chat.simplex.common.platform.defaultLocale
import java.util.*

fun Activity.saveAppLocale(pref: SharedPreference<String?>, languageCode: String? = null) {
  pref.set(languageCode)
  if (languageCode == null) {
    applyLocale(defaultLocale)
  }
  recreate()
}

fun Activity.applyAppLocale(pref: SharedPreference<String?>) {
  val lang = pref.get() ?: return
  applyLocale(Locale.forLanguageTag(lang))
}

private fun Activity.applyLocale(locale: Locale) {
  Locale.setDefault(locale)
  val appConf = Configuration(androidAppContext.resources.configuration).apply { setLocale(locale) }
  val activityConf = Configuration(resources.configuration).apply { setLocale(locale) }
  androidAppContext = androidAppContext.createConfigurationContext(appConf)
  @Suppress("DEPRECATION")
  resources.updateConfiguration(activityConf, resources.displayMetrics)
}

fun wrapContextWithLocale(context: Context, pref: SharedPreference<String?>): Context {
  val lang = pref.get() ?: return context
  val locale = Locale.forLanguageTag(lang)
  Locale.setDefault(locale)
  val config = Configuration(context.resources.configuration).apply { setLocale(locale) }
  return context.createConfigurationContext(config)
}
