/// Compara datas do calendário local sem depender da duração de cada dia.
int localDaysAgo(DateTime date, DateTime now) {
  DateTime calendarDay(DateTime value) {
    final local = value.toLocal();
    return DateTime.utc(local.year, local.month, local.day);
  }

  return calendarDay(now).difference(calendarDay(date)).inDays;
}
