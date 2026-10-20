/// A rebuild can refresh workouts without having historical sleep/RR data.
class ReanalysisResult {
  final int days;
  final int workouts;
  final int missingWorkouts;
  final String? error;

  const ReanalysisResult({
    this.days = 0,
    this.workouts = 0,
    this.missingWorkouts = 0,
    this.error,
  });

  String get message {
    final parts = <String>[
      'Rebuilt $days day${days == 1 ? '' : 's'} and $workouts workout HR '
          'summar${workouts == 1 ? 'y' : 'ies'}.',
      if (missingWorkouts > 0)
        '$missingWorkouts workout${missingWorkouts == 1 ? ' has' : 's have'} '
            'no saved HR readings to recover.',
      if (days == 0 && error == null)
        'No historical sensor days were rebuilt. Live HR still supports '
            'heart-rate averages; sleep and HRV need historical sensor data.',
      if (error != null) 'Analysis could not finish: $error',
    ];
    return parts.join('\n\n');
  }
}
