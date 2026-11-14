int resolveSortPosition({
  required List<String> previousOrder,
  required int currentIndex,
  required List<String> nextOrder,
  bool startOver = false,
}) {
  if (startOver || nextOrder.isEmpty || currentIndex < 0) return 0;
  if (previousOrder.isNotEmpty && currentIndex >= previousOrder.length) {
    return nextOrder.length;
  }

  if (currentIndex < previousOrder.length) {
    final currentItemIndex = nextOrder.indexOf(previousOrder[currentIndex]);
    if (currentItemIndex >= 0) return currentItemIndex;
  }
  return currentIndex.clamp(0, nextOrder.length - 1).toInt();
}
