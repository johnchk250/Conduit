// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Conduit';

  @override
  String get destinationHome => 'Home';

  @override
  String get destinationFolders => 'Folders';

  @override
  String get destinationDevices => 'Devices';

  @override
  String get destinationRemote => 'Remote';

  @override
  String get destinationSettings => 'Settings';

  @override
  String get onboardingTitle => 'Set up Conduit';

  @override
  String get connectionDoctorTitle => 'Connection Doctor';

  @override
  String pairedDeviceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count paired devices',
      one: '1 paired device',
      zero: 'No paired devices',
    );
    return '$_temp0';
  }
}
