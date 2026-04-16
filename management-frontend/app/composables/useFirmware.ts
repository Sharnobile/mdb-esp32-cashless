export type OtaDeviceStatus = 'pending' | 'sending' | 'sent' | 'failed'
export type OtaProgressCallback = (deviceId: string, status: OtaDeviceStatus, error?: string) => void

export interface FirmwareVersion {
  id: string
  created_at: string
  company_id: string
  version_label: string
  file_path: string
  file_size: number | null
  notes: string | null
  uploaded_by: string | null
  source_type: string | null
  source_tag: string | null
  is_public: boolean
  bootloader_path: string | null
  partition_table_path: string | null
}

export interface GitHubRelease {
  tag_name: string
  name: string
  published_at: string
  body: string | null
  html_url: string
  assets: GitHubAsset[]
}

export interface GitHubAsset {
  name: string
  size: number
  browser_download_url: string
}

// Session-lifetime cache of GitHub releases fetched by tag, shared across all useFirmware() call sites.
// Value `null` means "known missing on GitHub (404)" — cached to avoid repeat lookups.
// Transient errors (network failure, rate-limit) are NOT cached so the next attempt re-tries.
const releaseBodyCache = new Map<string, GitHubRelease | null>()

export interface ChangelogSource {
  /** Which data source the body came from. */
  kind: 'github-release' | 'notes' | 'none'
  /** The raw markdown/plaintext body to render. Empty string when kind === 'none'. */
  body: string
  /** Whether to render as Markdown (true) or plain text with preserved whitespace (false). */
  isMarkdown: boolean
  /** Release name if different from tag (GitHub sources only). */
  releaseName?: string
  /** ISO timestamp the GitHub release was published (GitHub sources only). */
  publishedAt?: string
  /** Assets on the release (GitHub sources only). */
  assets?: GitHubAsset[]
  /** External URL (GitHub html_url for releases, null for manual uploads). */
  externalUrl?: string
  /** Populated when a GitHub fetch was attempted and failed; triggers a "fetch failed" banner. */
  fetchFailed?: boolean
}

export function useFirmware() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  const firmwareVersions = ref<FirmwareVersion[]>([])
  const loading = ref(false)

  // ── GitHub releases ────────────────────────────────────────────────────
  const config = useRuntimeConfig()
  const githubRepo = computed(() => config.public.githubFirmwareRepo as string)
  const githubReleases = ref<GitHubRelease[]>([])
  const githubLoading = ref(false)

  async function fetchFirmwareVersions() {
    loading.value = true
    try {
      const { data, error } = await supabase
        .from('firmware_versions')
        .select('*')
        .order('created_at', { ascending: false })

      if (error) throw error
      firmwareVersions.value = (data as FirmwareVersion[]) ?? []
    } finally {
      loading.value = false
    }
  }

  async function uploadFirmware(file: File, versionLabel: string, notes?: string) {
    if (!organization.value) throw new Error('No organization')

    const filePath = `${organization.value.id}/${versionLabel}.bin`

    // Upload binary to storage
    const { error: uploadError } = await supabase.storage
      .from('firmware')
      .upload(filePath, file, {
        upsert: true,
        contentType: 'application/octet-stream',
      })
    if (uploadError) throw uploadError

    // Create database record
    const { error: insertError } = await supabase
      .from('firmware_versions')
      .insert({
        company_id: organization.value.id,
        version_label: versionLabel,
        file_path: filePath,
        file_size: file.size,
        notes: notes || null,
      })
    if (insertError) {
      // Clean up the uploaded file if DB insert fails
      await supabase.storage.from('firmware').remove([filePath])
      throw insertError
    }

    await fetchFirmwareVersions()
  }

  async function triggerOta(deviceId: string, firmwareId: string) {
    const { data, error } = await supabase.functions.invoke('trigger-ota', {
      body: { device_id: deviceId, firmware_id: firmwareId },
    })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    return data
  }

  async function triggerOtaBatch(
    deviceIds: string[],
    firmwareId: string,
    onProgress: OtaProgressCallback,
  ): Promise<{ sent: string[]; failed: { id: string; error: string }[] }> {
    const sent: string[] = []
    const failed: { id: string; error: string }[] = []

    for (const deviceId of deviceIds) {
      onProgress(deviceId, 'sending')
      try {
        await triggerOta(deviceId, firmwareId)
        sent.push(deviceId)
        onProgress(deviceId, 'sent')
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Unknown error'
        failed.push({ id: deviceId, error: msg })
        onProgress(deviceId, 'failed', msg)
      }
    }

    return { sent, failed }
  }

  async function deleteFirmwareVersion(id: string, filePath: string) {
    const fw = firmwareVersions.value.find(v => v.id === id)
    const filesToRemove = [filePath]
    if (fw?.bootloader_path) filesToRemove.push(fw.bootloader_path)
    if (fw?.partition_table_path) filesToRemove.push(fw.partition_table_path)

    await supabase.storage.from('firmware').remove(filesToRemove)
    const { error } = await supabase
      .from('firmware_versions')
      .delete()
      .eq('id', id)
    if (error) throw error
    await fetchFirmwareVersions()
  }

  async function updateFirmwareVersion(id: string, updates: Partial<Pick<FirmwareVersion, 'is_public'>>) {
    const { error } = await supabase
      .from('firmware_versions')
      .update(updates)
      .eq('id', id)
    if (error) throw error
    const idx = firmwareVersions.value.findIndex(fw => fw.id === id)
    if (idx !== -1) {
      firmwareVersions.value[idx] = { ...firmwareVersions.value[idx], ...updates }
    }
  }

  // ── GitHub release integration ─────────────────────────────────────────

  async function fetchGitHubReleases() {
    if (!githubRepo.value) return
    githubLoading.value = true
    try {
      const res = await $fetch<GitHubRelease[]>(
        `https://api.github.com/repos/${githubRepo.value}/releases`,
        { headers: { Accept: 'application/vnd.github.v3+json' } }
      )
      // Only show releases that have .bin assets
      githubReleases.value = res.filter(r =>
        r.assets.some(a => a.name.endsWith('.bin'))
      )
    } catch (e) {
      console.error('Failed to fetch GitHub releases:', e)
      githubReleases.value = []
    } finally {
      githubLoading.value = false
    }
  }

  /**
   * Return a GitHubRelease for the given tag, preferring:
   *   1. the already-loaded `githubReleases` array,
   *   2. the session cache,
   *   3. a single on-demand GitHub API call.
   *
   * Returns `null` if the repo is not configured, the tag does not exist on GitHub,
   * or the network fails. Null results are cached to avoid repeat 404s in the same session.
   */
  async function fetchReleaseByTag(tag: string): Promise<GitHubRelease | null> {
    if (!githubRepo.value || !tag) return null

    // 1) Already loaded via fetchGitHubReleases()
    const loaded = githubReleases.value.find(r => r.tag_name === tag)
    if (loaded) return loaded

    // 2) Cache hit (including negative cache)
    if (releaseBodyCache.has(tag)) {
      return releaseBodyCache.get(tag) ?? null
    }

    // 3) On-demand fetch
    try {
      const res = await $fetch<GitHubRelease>(
        `https://api.github.com/repos/${githubRepo.value}/releases/tags/${encodeURIComponent(tag)}`,
        { headers: { Accept: 'application/vnd.github.v3+json' } },
      )
      releaseBodyCache.set(tag, res)
      return res
    } catch (e: unknown) {
      // Only cache genuine 404s. Transient errors (network, rate-limit, 5xx) should re-try on next open.
      const status = (e as { statusCode?: number; status?: number })?.statusCode
        ?? (e as { status?: number })?.status
      if (status === 404) {
        releaseBodyCache.set(tag, null)
      }
      console.warn(`[useFirmware] Failed to fetch GitHub release for tag "${tag}" (status=${status ?? 'unknown'}):`, e)
      return null
    }
  }

  /**
   * Resolve the changelog to display for a given firmware_versions row.
   *
   *  - GitHub-sourced firmware → try to find/fetch the release; on success return Markdown.
   *    On failure (deleted release, rate-limited, offline), fall back to the stored `notes` field
   *    (500-char truncation is acceptable as a fallback) and set `fetchFailed: true` so the UI can
   *    render a banner above the body.
   *  - Manual uploads → always plaintext `notes`.
   */
  async function getChangelogForFirmware(fw: FirmwareVersion): Promise<ChangelogSource> {
    if (fw.source_type === 'github' && fw.source_tag) {
      const release = await fetchReleaseByTag(fw.source_tag)
      if (release) {
        return {
          kind: 'github-release',
          body: release.body ?? '',
          isMarkdown: true,
          releaseName: release.name && release.name !== release.tag_name ? release.name : undefined,
          publishedAt: release.published_at,
          assets: release.assets,
          externalUrl: release.html_url,
        }
      }
      // Fall back to stored notes. Only flag fetchFailed when the repo is configured
      // (i.e. a fetch was actually attempted) — otherwise the banner would be misleading.
      return {
        kind: fw.notes ? 'notes' : 'none',
        body: fw.notes ?? '',
        isMarkdown: false,
        fetchFailed: Boolean(githubRepo.value),
        externalUrl: githubRepo.value
          ? `https://github.com/${githubRepo.value}/releases/tag/${encodeURIComponent(fw.source_tag)}`
          : undefined,
      }
    }

    // Manual upload (or anything else)
    return {
      kind: fw.notes ? 'notes' : 'none',
      body: fw.notes ?? '',
      isMarkdown: false,
    }
  }

  async function importGitHubRelease(
    tag: string,
    assetName: string,
    versionLabel?: string,
    notes?: string,
  ) {
    const { data, error } = await supabase.functions.invoke('import-github-release', {
      body: { tag, asset_name: assetName, version_label: versionLabel, notes },
    })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    await fetchFirmwareVersions()
    return data
  }

  /** Check if a GitHub release tag has already been imported */
  function isReleaseImported(tag: string): boolean {
    return firmwareVersions.value.some(fw => fw.source_tag === tag)
  }

  return {
    firmwareVersions,
    loading,
    fetchFirmwareVersions,
    uploadFirmware,
    triggerOta,
    triggerOtaBatch,
    deleteFirmwareVersion,
    updateFirmwareVersion,
    // GitHub integration
    githubRepo,
    githubReleases,
    githubLoading,
    fetchGitHubReleases,
    importGitHubRelease,
    isReleaseImported,
    // Changelog
    fetchReleaseByTag,
    getChangelogForFirmware,
  }
}
