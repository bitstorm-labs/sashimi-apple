import SwiftUI

extension MediaDetailView {
    /// Resolution / video codec / audio codec chips. Shared so movies can put
    /// them on their own row while series and episodes keep them inline.
    @ViewBuilder
    var qualityBadges: some View {
        if let info = mediaInfo {
            if let resolution = info.videoResolution {
                mediaInfoBadge(resolution)
            }
            if let videoCodec = info.videoCodec {
                mediaInfoBadge(formatCodec(videoCodec))
            }
            if let audioCodec = info.audioCodec, let channels = info.audioChannels {
                audioInfoBadge(codec: audioCodec, channels: channels)
            }
        }
    }

    private func mediaInfoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func audioInfoBadge(codec: String, channels: Int) -> some View {
        if let logoName = audioCodecLogoName(codec) {
            HStack(spacing: 8) {
                Image(logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                Text(formatChannels(channels))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
        } else {
            mediaInfoBadge("\(formatCodec(codec)) \(formatChannels(channels))")
        }
    }

    private func audioCodecLogoName(_ codec: String) -> String? {
        let upper = codec.uppercased()
        switch upper {
        case "AC3": return "DolbyDigital"
        case "EAC3": return "DolbyDigitalPlus"
        case "TRUEHD": return "DolbyTrueHD"
        case "DTS", "DCA": return "DTS"
        default: return nil
        }
    }

    private func formatCodec(_ codec: String) -> String {
        let upper = codec.uppercased()
        switch upper {
        case "HEVC", "H265": return "HEVC"
        case "H264", "AVC": return "H.264"
        case "AV1": return "AV1"
        case "AAC": return "AAC"
        case "AC3": return "Dolby Digital"
        case "EAC3": return "Dolby Digital+"
        case "TRUEHD": return "Dolby TrueHD"
        case "DTS": return "DTS"
        case "FLAC": return "FLAC"
        default: return upper
        }
    }

    private func formatChannels(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    var metadataLabel: String {
        var parts: [String] = []

        if isEpisode {
            // Premiere date only - S#:E# is now in title
            if let premiereDateStr = item.premiereDate {
                if let formatted = DateFormatting.formatLongDate(premiereDateStr) {
                    parts.append(formatted)
                }
            }
        }

        if isSeries {
            // For series: show year and season count
            if let year = item.productionYear {
                parts.append(String(year))
            }
            let seasonCount = seasons.count
            if seasonCount > 0 {
                parts.append(seasonCount == 1 ? "1 Season" : "\(seasonCount) Seasons")
            }
        } else {
            // Movie: release year, then runtime.
            if let year = item.productionYear {
                parts.append(String(year))
            }
            if let runtime = DateFormatting.formatRuntime(item.runTimeTicks) {
                parts.append(runtime)
            }
        }

        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    var ratingsRow: some View {
        // Use series ratings as fallback for episodes
        let communityRating = item.communityRating ?? seriesCommunityRating
        let criticRating = item.criticRating ?? seriesCriticRating
        let hasCommunityRating = (communityRating ?? 0) > 0
        let hasCriticRating = criticRating != nil

        if hasCommunityRating || hasCriticRating {
            HStack(spacing: 20) {
                if let rating = communityRating, rating > 0 {
                    HStack(spacing: 8) {
                        Image("TMDBLogo")
                            .resizable().scaledToFit()
                            .frame(height: 24)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 18, weight: .bold))
                    }
                }

                if let critic = criticRating {
                    HStack(spacing: 6) {
                        Text("🍅")
                            .font(.system(size: 18))
                        Text("\(critic)%")
                            .font(.system(size: 18, weight: .bold))
                    }
                }
            }
            .foregroundStyle(SashimiTheme.textPrimary)
        }
    }

    /// Calculates and formats the finish time if playback started now
    var finishTimeString: String? {
        guard let totalTicks = item.runTimeTicks, totalTicks > 0 else { return nil }

        // Calculate remaining time (account for any progress)
        let watchedTicks = item.userData?.playbackPositionTicks ?? 0
        let remainingTicks = totalTicks - watchedTicks
        guard remainingTicks > 0 else { return nil }

        let remainingSeconds = TimeInterval(remainingTicks) / 10_000_000
        let finishDate = Date().addingTimeInterval(remainingSeconds)

        return "Ends at \(ClockTime.time(finishDate))"
    }
}
