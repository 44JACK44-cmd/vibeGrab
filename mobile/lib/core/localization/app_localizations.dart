import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;
  late Map<String, String> _strings;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('es'),
    Locale('en'),
  ];

  Future<bool> load() async {
    final fileName = 'app_${locale.languageCode}.arb';
    final jsonString = await rootBundle.loadString('lib/core/localization/$fileName');
    final Map<String, dynamic> jsonMap = json.decode(jsonString);

    _strings = {};
    for (final entry in jsonMap.entries) {
      if (!entry.key.startsWith('@')) {
        _strings[entry.key] = entry.value.toString();
      }
    }
    return true;
  }

  String _get(String key, [Map<String, String>? params]) {
    var value = _strings[key] ?? key;
    if (params != null) {
      for (final entry in params.entries) {
        value = value.replaceAll('{${entry.key}}', entry.value);
      }
    }
    return value;
  }

  String get appName => _get('appName');

  String get navAnalyze => _get('navAnalyze');
  String get navDownloads => _get('navDownloads');
  String get navLibrary => _get('navLibrary');
  String get navSettings => _get('navSettings');
  String get navExplore => _get('navExplore');

  String get urlHint => _get('urlHint');
  String get analyzeButton => _get('analyzeButton');
  String get analyzing => _get('analyzing');
  String get pasteAndAnalyze => _get('pasteAndAnalyze');
  String get clear => _get('clear');
  String get pleaseEnterUrl => _get('pleaseEnterUrl');
  String get analysisFailed => _get('analysisFailed');
  String downloadAdded(String title) => _get('downloadAdded', {'title': title});
  String downloadError(String error) => _get('downloadError', {'error': error});

  String get formatAudio => _get('formatAudio');
  String get formatVideo => _get('formatVideo');
  String get formatVideoAudio => _get('formatVideoAudio');
  String get formatVideoOnly => _get('formatVideoOnly');
  String formatAudioLabel(String quality) => _get('formatAudioLabel', {'quality': quality});
  String get downloadAsMusic => _get('downloadAsMusic');
  String get downloadAsVideo => _get('downloadAsVideo');

  String get statusQueued => _get('statusQueued');
  String get statusPreparing => _get('statusPreparing');
  String get statusResolving => _get('statusResolving');
  String get statusConnecting => _get('statusConnecting');
  String get statusDownloading => _get('statusDownloading');
  String get statusSaving => _get('statusSaving');
  String get statusMerging => _get('statusMerging');
  String get statusCompleted => _get('statusCompleted');
  String get statusFailed => _get('statusFailed');
  String get statusCancelled => _get('statusCancelled');
  String get statusPaused => _get('statusPaused');
  String statusRetrying(String count) => _get('statusRetrying', {'count': count});

  String get downloadStepPreparing => _get('downloadStepPreparing');
  String get downloadStepParsing => _get('downloadStepParsing');
  String get downloadStepFetchingManifest => _get('downloadStepFetchingManifest');
  String get downloadStepSelectingStream => _get('downloadStepSelectingStream');
  String get downloadStepConnecting => _get('downloadStepConnecting');
  String get downloadStepDownloading => _get('downloadStepDownloading');
  String get downloadStepMuxing => _get('downloadStepMuxing');
  String get downloadStepSaving => _get('downloadStepSaving');

  String get downloadErrorStorageNotConfigured => _get('downloadErrorStorageNotConfigured');
  String get downloadErrorStorageNotWritable => _get('downloadErrorStorageNotWritable');
  String get downloadErrorInvalidUrl => _get('downloadErrorInvalidUrl');
  String get downloadErrorFormatNotFound => _get('downloadErrorFormatNotFound');
  String get downloadErrorNoStreams => _get('downloadErrorNoStreams');
  String get downloadErrorStreamsTimeout => _get('downloadErrorStreamsTimeout');
  String get downloadErrorStreamsFailed => _get('downloadErrorStreamsFailed');
  String get downloadErrorUrlNull => _get('downloadErrorUrlNull');
  String get downloadErrorHttpError => _get('downloadErrorHttpError');
  String get downloadErrorHttp403 => _get('downloadErrorHttp403');
  String get downloadErrorConnectionTimeout => _get('downloadErrorConnectionTimeout');
  String get downloadErrorServerTimeout => _get('downloadErrorServerTimeout');
  String get downloadErrorConnectionFailed => _get('downloadErrorConnectionFailed');
  String get downloadErrorFileEmpty => _get('downloadErrorFileEmpty');
  String get downloadErrorMuxNoAudio => _get('downloadErrorMuxNoAudio');
  String get downloadErrorCancelled => _get('downloadErrorCancelled');
  String get downloadErrorGeneric => _get('downloadErrorGeneric');

  String get downloadingAudio => _get('downloadingAudio');
  String get audioDownloaded => _get('audioDownloaded');
  String get errorDownloadingAudio => _get('errorDownloadingAudio');

  String localizedDownloadError(String? errorCode) {
    switch (errorCode) {
      case 'storageNotConfigured': return downloadErrorStorageNotConfigured;
      case 'storageNotWritable': return downloadErrorStorageNotWritable;
      case 'invalidUrl': return downloadErrorInvalidUrl;
      case 'formatNotFound': return downloadErrorFormatNotFound;
      case 'noStreams': return downloadErrorNoStreams;
      case 'streamsTimeout': return downloadErrorStreamsTimeout;
      case 'streamsFailed': return downloadErrorStreamsFailed;
      case 'urlNull': return downloadErrorUrlNull;
      case 'httpError': return downloadErrorHttpError;
      case 'http403': return downloadErrorHttp403;
      case 'connectionTimeout': return downloadErrorConnectionTimeout;
      case 'serverTimeout': return downloadErrorServerTimeout;
      case 'connectionFailed': return downloadErrorConnectionFailed;
      case 'fileEmpty': return downloadErrorFileEmpty;
      case 'muxNoAudio': return downloadErrorMuxNoAudio;
      case 'cancelled': return downloadErrorCancelled;
      default: return downloadErrorGeneric;
    }
  }

  String localizedDownloadStep(String? step) {
    switch (step) {
      case 'preparing': return downloadStepPreparing;
      case 'resolving': return downloadStepResolving;
      case 'connecting': return downloadStepConnecting;
      case 'downloading': return downloadStepDownloading;
      case 'processing': return downloadStepMuxing;
      case 'saving': return downloadStepSaving;
      default: return '';
    }
  }

  String get downloadStepResolving => _get('downloadStepResolving');

  String get downloadsTitle => _get('downloadsTitle');
  String get clearCompleted => _get('clearCompleted');
  String get noDownloads => _get('noDownloads');
  String get noDownloadsHint => _get('noDownloadsHint');

  String get libraryTitle => _get('libraryTitle');
  String get refresh => _get('refresh');
  String get retry => _get('retry');
  String get noFiles => _get('noFiles');
  String get noFilesHint => _get('noFilesHint');
  String fileCount(int count) {
    if (count == 0) return '0 files';
    if (count == 1) return '1 file';
    return '$count files';
  }

  String get deleteFileTitle => _get('deleteFileTitle');
  String deleteFileConfirm(String title) => _get('deleteFileConfirm', {'title': title});
  String get cancel => _get('cancel');
  String get delete => _get('delete');

  String get settingsTitle => _get('settingsTitle');
  String get sectionAppearance => _get('sectionAppearance');
  String get sectionDownloads => _get('sectionDownloads');
  String get sectionBehavior => _get('sectionBehavior');
  String get sectionAbout => _get('sectionAbout');
  String get sectionLanguage => _get('sectionLanguage');
  String get sectionServer => _get('sectionServer');
  String get sectionGeneral => _get('sectionGeneral');
  String get sectionNotifications => _get('sectionNotifications');

  String get defaultQuality => _get('defaultQuality');
  String get defaultQualityHint => _get('defaultQualityHint');
  String get qualityBest => _get('qualityBest');
  String get qualityAudioOnly => _get('qualityAudioOnly');
  String get speedLimit => _get('speedLimit');
  String get speedLimitHint => _get('speedLimitHint');
  String get speedUnlimited => _get('speedUnlimited');
  String get notifyCompleted => _get('notifyCompleted');
  String get notifyCompletedHint => _get('notifyCompletedHint');
  String get notifyErrors => _get('notifyErrors');
  String get notifyErrorsHint => _get('notifyErrorsHint');
  String get notifySound => _get('notifySound');
  String get notifySoundHint => _get('notifySoundHint');
  String get serverStatus => _get('serverStatus');
  String get serverOnline => _get('serverOnline');
  String get serverOffline => _get('serverOffline');
  String get serverChecking => _get('serverChecking');
  String get checkNow => _get('checkNow');
  String get recommendedFormat => _get('recommendedFormat');

  String get sectionTools => _get('sectionTools');
  String get trash => _get('trash');
  String get trashHint => _get('trashHint');
  String get trashEmpty => _get('trashEmpty');
  String get restore => _get('restore');
  String get deleteForever => _get('deleteForever');
  String get emptyTrash => _get('emptyTrash');
  String get emptyTrashConfirm => _get('emptyTrashConfirm');
  String get trashRestored => _get('trashRestored');
  String get vault => _get('vault');
  String get vaultHint => _get('vaultHint');
  String get vaultEmpty => _get('vaultEmpty');
  String get createPin => _get('createPin');
  String get createPinHint => _get('createPinHint');
  String get confirmPin => _get('confirmPin');
  String get enterPin => _get('enterPin');
  String get wrongPin => _get('wrongPin');
  String get pinMismatch => _get('pinMismatch');
  String get pinLocked => _get('pinLocked');
  String get unlock => _get('unlock');
  String get vaultMoveAction => _get('vaultMoveAction');
  String get vaultMoved => _get('vaultMoved');
  String get movedToTrash => _get('movedToTrash');

  String get backendUrl => _get('backendUrl');
  String get backendUrlHint => _get('backendUrlHint');
  String get backendUrlPlaceholder => _get('backendUrlPlaceholder');
  String get backendNotConfigured => _get('backendNotConfigured');
  String get backendConfigured => _get('backendConfigured');
  String get resetDefault => _get('resetDefault');
  String get save => _get('save');
  String get directorySelected => _get('directorySelected');

  String get permissionRequiredTitle => _get('permissionRequiredTitle');
  String get permissionRequiredHint => _get('permissionRequiredHint');
  String get grantPermission => _get('grantPermission');
  String get openSettings => _get('openSettings');

  String get errorBackendUnavailable => _get('errorBackendUnavailable');
  String get errorBackendUnavailableHint => _get('errorBackendUnavailableHint');
  String get onlineReady => _get('onlineReady');
  String get noInternetConnection => _get('noInternetConnection');

  String get downloadDirectory => _get('downloadDirectory');
  String get maxConcurrentDownloads => _get('maxConcurrentDownloads');
  String get maxFileSize => _get('maxFileSize');
  String get autoOpen => _get('autoOpen');
  String get autoOpenHint => _get('autoOpenHint');
  String get preferBestQuality => _get('preferBestQuality');
  String get preferBestQualityHint => _get('preferBestQualityHint');
  String get saveMetadata => _get('saveMetadata');
  String get saveMetadataHint => _get('saveMetadataHint');
  String get appVersion => _get('appVersion');

  String get language => _get('language');
  String get languageAuto => _get('languageAuto');
  String get languageSpanish => _get('languageSpanish');
  String get languageEnglish => _get('languageEnglish');

  String get untitled => _get('untitled');
  String get unknown => _get('unknown');

  String sourceLabel(String source) {
    switch (source) {
      case 'youtube': return _get('sourceYouTube');
      case 'tiktok': return _get('sourceTikTok');
      case 'instagram': return _get('sourceInstagram');
      case 'twitter': return _get('sourceTwitter');
      case 'facebook': return _get('sourceFacebook');
      case 'vimeo': return _get('sourceVimeo');
      case 'dailymotion': return _get('sourceDailymotion');
      case 'soundcloud': return _get('sourceSoundCloud');
      default: return source;
    }
  }

  String get errorFailedLoadLibrary => _get('errorFailedLoadLibrary');
  String get errorFailedDeleteFile => _get('errorFailedDeleteFile');
  String get errorFailedStartDownload => _get('errorFailedStartDownload');
  String get errorFailedGetStatus => _get('errorFailedGetStatus');
  String get errorFailedRetryDownload => _get('errorFailedRetryDownload');
  String get errorFailedLoadSettings => _get('errorFailedLoadSettings');
  String get errorFailedSaveSettings => _get('errorFailedSaveSettings');
  String get errorFailedCancelDownload => _get('errorFailedCancelDownload');
  String get errorFailedLoadDownloads => _get('errorFailedLoadDownloads');
  String get errorNoConnection => _get('errorNoConnection');
  String get errorNoConnectionHint => _get('errorNoConnectionHint');
  String get errorSearchFailed => _get('errorSearchFailed');
  String get errorServerUnavailable => _get('errorServerUnavailable');
  String get errorRetrying => _get('errorRetrying');

  String get tabAll => _get('tabAll');
  String get tabVideos => _get('tabVideos');
  String get tabAudio => _get('tabAudio');
  String get tabFavorites => _get('tabFavorites');
  String get tabHistory => _get('tabHistory');

  String get resumeLeft => _get('resumeLeft');

  String get openFile => _get('openFile');
  String get fileInfo => _get('fileInfo');
  String get titleLabel => _get('titleLabel');
  String get fileName => _get('fileName');
  String get typeLabel => _get('typeLabel');
  String get sizeLabel => _get('sizeLabel');
  String get close => _get('close');

  String get deleteConfirmTitle => _get('deleteConfirmTitle');
  String get deleteConfirmContent => _get('deleteConfirmContent');

  String get exploreSearchHint => _get('exploreSearchHint');
  String get exploreIdleHint => _get('exploreIdleHint');
  String get recentSearches => _get('recentSearches');
  String get clearRecent => _get('clearRecent');
  String get noResults => _get('noResults');
  String get noResultsHint => _get('noResultsHint');
  String get downloadVideo => _get('downloadVideo');
  String get playVideo => _get('playVideo');

  String get shareDownloadTitle => _get('shareDownloadTitle');
  String get shareAnalyzing => _get('shareAnalyzing');
  String get shareVideo => _get('shareVideo');
  String get shareAudio => _get('shareAudio');
  String get shareDownload => _get('shareDownload');
  String get shareCancel => _get('shareCancel');
  String get shareRetry => _get('shareRetry');
  String get shareNoFormats => _get('shareNoFormats');
  String get shareAnalysisFailed => _get('shareAnalysisFailed');
  String get shareServerUnavailable => _get('shareServerUnavailable');
  String get shareConfigureServer => _get('shareConfigureServer');
  String get shareTimeout => _get('shareTimeout');
  String get sharePreparingDownload => _get('sharePreparingDownload');
  String get shareDownloadStarted => _get('shareDownloadStarted');
  String get shareNoInternet => _get('shareNoInternet');
  String get shareUnsupportedPlatform => _get('shareUnsupportedPlatform');
  String get shareContentUnavailable => _get('shareContentUnavailable');
  String get shareUnsupportedPlatformDesc => _get('shareUnsupportedPlatformDesc');
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['es', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final localizations = AppLocalizations(locale);
    await localizations.load();
    return localizations;
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) => false;
}
