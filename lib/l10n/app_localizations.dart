import 'package:flutter/material.dart';

/// App strings in English and Khmer.
/// Use [AppLocalizations.of(context).tr(key)] to get the translated string.
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static const Map<String, Map<String, String>> _strings = {
    'en': {
      'messages': 'Messages',
      'connect': 'Connect',
      'settings': 'Settings',
      'username': 'Username',
      'changeUsername': 'Change',
      'contacts': 'Contacts',
      'search': 'Find a contact',
      'groups': 'Groups',
      'availableRadios': 'Available Radios',
      'manual': 'Manual',
      'directMessages': 'Direct Messages',
      'appearance': 'Appearance',
      'changeThemes': 'Change the themes',
      'darkMode': 'Dark Mode',
      'lightMode': 'Light Mode',
      'languages': 'Languages',
      'changeLanguages': 'Change languages',
      'english': 'English',
      'khmer': 'Khmer',
      'preferences': 'Preferences',
      'notifications': 'Notifications',
      'notificationsSubtitle': 'Receive message notifications',
      'locationSharing': 'Location Sharing',
      'locationSharingSubtitle': 'Share your location with mesh network',
      'about': 'About',
      'appVersion': 'App Version',
      'helpSupport': 'Help & Support',
      'connectViaWiFi': 'Connect via WiFi',
      'connectViaWiFiSubtitle': 'Connect to a LoRa device over WiFi network',
      'connectViaBluetooth': 'Connect via Bluetooth',
      'connectViaBluetoothSubtitle': 'Connect to a LoRa device via Bluetooth',
      'cancalButton': 'Cancel',
      'connectButton': 'Connect',
      'detailsMessage':'You can send and receive channel (group chats) and direct messages. From any message you can long press to see available actions like copy, reply, tapback and delete as well as delivery details'
    },
    'km': {
      'messages': 'សារ',
      'connect': 'ភ្ជាប់',
      'settings': 'ការកំណត់',
      'username': 'ឈ្មោះអ្នកប្រើប្រាស់',
      'changeUsername': 'ផ្លាស់ប្តូរ',
      'contacts': 'ទំនាក់ទំនង',
      'search': 'ស្វែងរកទំនាក់ទំនង',
      'groups': 'ជជែកជាក្រុម',
      'availableRadios': 'ឧបករណ៍បណ្តាញ',
      'manual': 'ការប្រើប្រាស់',
      'directMessages': 'សារ',
      'appearance': 'រូបរាង',
      'changeThemes': 'ផ្លាស់ប្តូរផ្ទាំង',
      'darkMode': 'ផ្ទាំងងងឹត',
      'lightMode': 'ផ្ទាំងភ្លឺ',
      'languages': 'ភាសា',
      'changeLanguages': 'ផ្លាស់ប្តូរភាសា',
      'english': 'អង់គ្លេស',
      'khmer': 'ខ្មែរ',
      'preferences': 'ចំណូលចិត្ត',
      'notifications': 'ការជូនដំណឹង',
      'notificationsSubtitle': 'ទទួលការជូនដំណឹងសារ',
      'locationSharing': 'ការចែករងទីតាំង',
      'locationSharingSubtitle': 'ចែករងទីតាំងរបស់អ្នកជាមួយបណ្តាញ mesh',
      'about': 'អំពី',
      'appVersion': 'កំណែកម្មវិធី',
      'helpSupport': 'ជំនួយ និងគាំទ្រ',
      'connectViaWiFi': 'ភ្ជាប់តាម WiFi',
      'connectViaWiFiSubtitle': 'ភ្ជាប់ទៅឧបករណ៍ LoRa តាមរយៈ WiFi',
      'connectViaBluetooth': 'ភ្ជាប់តាម Bluetooth',
      'connectViaBluetoothSubtitle': 'ភ្ជាប់ទៅឧបករណ៍ LoRa តាមរយៈប៊្លូធូស',
      'cancalButton': 'បិទ',
      'connectButton': 'ភ្ជាប់',
      'detailsMessage': 'អ្នកអាចផ្ញើ និងទទួលសារ (ជជែកជាក្រុម) និងសារផ្ទាល់។ ពីសារណាមួយ អ្នកអាចចុចឱ្យយូរដើម្បីមើលសកម្មភាពដែលមានដូចជា ចម្លង ឆ្លើយតប ប៉ះថយក្រោយ និងលុប ក៏ដូចជាព័ត៌មានលម្អិតនៃការដឹកជញ្ជូន។'
    },
  };

  String tr(String key) {
    return _strings[locale.languageCode]?[key] ??
        _strings['en']?[key] ??
        key;
  }

  static AppLocalizations of(BuildContext context) {
    final data = context.dependOnInheritedWidgetOfExactType<_InheritedAppLocalizations>();
    assert(data != null, 'No AppLocalizations found in context');
    return data!.localizations;
  }

  static AppLocalizations? maybeOf(BuildContext context) {
    final data = context.dependOnInheritedWidgetOfExactType<_InheritedAppLocalizations>();
    return data?.localizations;
  }

  /// Wraps [child] so that [AppLocalizations.of(context)] works with [locale].
  static Widget wrap({required Locale locale, required Widget child}) {
    return _InheritedAppLocalizations(
      localizations: AppLocalizations(locale),
      child: child,
    );
  }
}

class _InheritedAppLocalizations extends InheritedWidget {
  const _InheritedAppLocalizations({
    required this.localizations,
    required super.child,
  });

  final AppLocalizations localizations;

  @override
  bool updateShouldNotify(_InheritedAppLocalizations old) =>
      localizations.locale != old.localizations.locale;
}
