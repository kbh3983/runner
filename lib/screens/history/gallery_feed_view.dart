import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/app_paths.dart';
import '../../services/auth_service.dart';
import '../../services/route_repository.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';
import 'certificate_sheet.dart';

/// 러닝 포토 갤러리 & 피드 뷰:
/// 달릴 때 촬영한 사진들과 러닝 경로 스냅샷을 인스타그램 피드 및 앨범 스타일로 감상
class GalleryFeedView extends StatefulWidget {
  const GalleryFeedView({
    super.key,
    required this.runs,
    required this.photos,
    required this.onOpenRun,
    this.isGridView = true,
  });

  final List<RunRecord> runs;
  final Map<String, RunPhoto> photos;
  final void Function(RunRecord run) onOpenRun;
  final bool isGridView;

  @override
  State<GalleryFeedView> createState() => _GalleryFeedViewState();
}

class _GalleryFeedViewState extends State<GalleryFeedView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final runs = widget.runs;
    if (runs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 56,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 16),
              const Text(
                '아직 러닝 추억이 없어요',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                '달린 후 사진을 남기거나 경로 스냅샷을 모아\n나만의 러닝 갤러리를 완성해보세요 📸',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: widget.isGridView
          ? KeyedSubtree(
              key: const ValueKey('grid_view'),
              child: _buildGridView(runs),
            )
          : KeyedSubtree(
              key: const ValueKey('feed_view'),
              child: _buildFeedView(runs),
            ),
    );
  }

  // ---------------------------------------------------------------- 피드 뷰 (인스타 스타일)

  Widget _buildFeedView(List<RunRecord> runs) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      itemCount: runs.length,
      itemBuilder: (context, index) {
        final run = runs[index];
        final photo = widget.photos[run.id];
        return _FeedCard(
          run: run,
          photo: photo,
          onTap: () => widget.onOpenRun(run),
        );
      },
    );
  }

  // ---------------------------------------------------------------- 그리드 뷰 (월별 그룹화 3x3 앨범 스타일)

  Widget _buildGridView(List<RunRecord> runs) {
    // 월별 그룹화 (최신순)
    final Map<String, List<RunRecord>> grouped = {};
    for (final run in runs) {
      final date = DateTime.fromMillisecondsSinceEpoch(run.startedAt);
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(key, () => []).add(run);
    }

    return CustomScrollView(
      slivers: [
        for (final entry in grouped.entries) ...[
          SliverToBoxAdapter(
            child: _buildMonthHeader(entry.key, entry.value),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final run = entry.value[index];
                  return _buildGridTile(run);
                },
                childCount: entry.value.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(
          child: SizedBox(height: 48),
        ),
      ],
    );
  }

  Widget _buildMonthHeader(String monthKey, List<RunRecord> monthRuns) {
    final parts = monthKey.split('-');
    final year = parts[0];
    final month = int.tryParse(parts[1]) ?? parts[1];
    final totalDistance = monthRuns.fold<double>(0, (s, r) => s + r.distanceM);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '$year년 $month월',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${monthRuns.length}회  ·  ${Fmt.km(totalDistance, digits: 1)} km',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.neon,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridTile(RunRecord run) {
    final photo = widget.photos[run.id];
    final thumbFile = ThumbnailService.instance.fileFor(run);

    Widget imageWidget;
    if (photo != null && AppPaths.resolve(photo.relPath).existsSync()) {
      imageWidget = Image.file(
        AppPaths.resolve(photo.relPath),
        fit: BoxFit.cover,
        cacheWidth: 350,
      );
    } else if (thumbFile != null && thumbFile.existsSync()) {
      imageWidget = Image.file(
        thumbFile,
        fit: BoxFit.cover,
        cacheWidth: 350,
      );
    } else {
      imageWidget = Container(
        color: AppColors.surfaceHigh,
        child: const Icon(Icons.directions_run_rounded, color: AppColors.neon, size: 28),
      );
    }

    return InkWell(
      onTap: () => widget.onOpenRun(run),
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageWidget,
          // 하단 거리 뱃지
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${Fmt.km(run.distanceM, digits: 1)}k',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          if (photo != null)
            const Positioned(
              right: 4,
              top: 4,
              child: Icon(Icons.photo_camera_rounded, size: 12, color: Colors.white70),
            ),
        ],
      ),
    );
  }
}

/// 인스타그램 피드 스타일의 러닝 카드
class _FeedCard extends StatelessWidget {
  const _FeedCard({
    required this.run,
    required this.photo,
    required this.onTap,
  });

  final RunRecord run;
  final RunPhoto? photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbFile = ThumbnailService.instance.fileFor(run);
    final hasPhoto = photo != null && AppPaths.resolve(photo!.relPath).existsSync();

    Widget mainMedia;
    if (hasPhoto) {
      mainMedia = Image.file(
        AppPaths.resolve(photo!.relPath),
        fit: BoxFit.cover,
      );
    } else if (thumbFile != null && thumbFile.existsSync()) {
      mainMedia = Image.file(
        thumbFile,
        fit: BoxFit.cover,
      );
    } else {
      mainMedia = Container(
        color: const Color(0xFF1D2026),
        alignment: Alignment.center,
        child: const Icon(Icons.directions_run_rounded, color: AppColors.neon, size: 48),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outline.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 상단 프로필 및 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.surfaceHigh,
                  child: Icon(Icons.person, size: 18, color: AppColors.neon),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        run.ownerName.isNotEmpty ? run.ownerName : AuthService.instance.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                      ),
                      Row(
                        children: [
                          Text(
                            Fmt.dateTime(run.startedAt),
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                          ),
                          if (run.region != null && run.region!.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            const Text('·', style: TextStyle(color: AppColors.textSecondary)),
                            const SizedBox(width: 4),
                            const Icon(Icons.location_on, size: 11, color: AppColors.neon),
                            Flexible(
                              child: Text(
                                run.region!,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // 공유 버튼 (인스타 기록증)
                IconButton(
                  icon: const Icon(Icons.ios_share_rounded, size: 20, color: AppColors.textSecondary),
                  tooltip: '기록증 공유',
                  onPressed: () async {
                    final segs = await RouteRepository.segmentsFor(run);
                    if (context.mounted) {
                      showCertificateSheet(context, run: run, segments: segs);
                    }
                  },
                ),
              ],
            ),
          ),

          // 1:1 직각 네모 미디어 (인스타 1:1 사진/경로)
          GestureDetector(
            onTap: onTap,
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRect(
                child: mainMedia,
              ),
            ),
          ),

          // 하단 러닝 스탯 및 정보
          InkWell(
            onTap: onTap,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${Fmt.km(run.distanceM)} km',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: AppColors.neon,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        '${Fmt.pace(run.avgPaceSecPerKm)} /km',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '·  ${Fmt.duration(run.durationMs)}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      if (run.isGroup)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.groups_rounded, size: 13, color: Colors.lightBlueAccent),
                              SizedBox(width: 4),
                              Text(
                                '같이뛰기',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.lightBlueAccent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
