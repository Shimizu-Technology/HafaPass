import { useState, useEffect, useRef, useCallback } from 'react'
import apiClient from '../../api/client'

export default function ScannerPage() {
 const [scanResult, setScanResult] = useState(null) // { type: 'success'|'warning'|'error', data }
 const [scanning, setScanning] = useState(false)
 const [cameraError, setCameraError] = useState(null)
 const [manualCode, setManualCode] = useState('')
 const [manualSubmitting, setManualSubmitting] = useState(false)
 const [sessionCount, setSessionCount] = useState(0)
 const [useBarcodeDetector, setUseBarcodeDetector] = useState(false)

 const videoRef = useRef(null)
 const canvasRef = useRef(null)
 const streamRef = useRef(null)
 const scanIntervalRef = useRef(null)
 const resetTimerRef = useRef(null)

 const processCheckIn = useCallback(async (qrCode) => {
  if (!qrCode || qrCode.trim() === '') return

  try {
   const response = await apiClient.post(`/check_in/${encodeURIComponent(qrCode.trim())}`)
   setScanResult({
    type: 'success',
    message: 'Check-in successful!',
    ticket: response.data.ticket
   })
   setSessionCount(prev => prev + 1)
  } catch (err) {
   if (err.response?.status === 404) {
    setScanResult({
     type: 'error',
     message: 'Invalid ticket',
     detail: 'This QR code does not match any ticket.'
    })
   } else if (err.response?.status === 422) {
    const data = err.response.data
    if (data.error?.includes('already checked in')) {
     setScanResult({
      type: 'warning',
      message: 'Already checked in',
      detail: `Checked in at ${new Date(data.checked_in_at).toLocaleTimeString()}`,
      ticket: data.ticket
     })
    } else {
     setScanResult({
      type: 'error',
      message: data.error || 'Check-in failed',
      ticket: data.ticket
     })
    }
   } else {
    setScanResult({
     type: 'error',
     message: 'Network error',
     detail: 'Could not connect to the server. Please try again.'
    })
   }
  }

  // Auto-reset after 3 seconds
  if (resetTimerRef.current) clearTimeout(resetTimerRef.current)
  resetTimerRef.current = setTimeout(() => {
   setScanResult(null)
  }, 3000)
 }, [])

 const startCamera = useCallback(async () => {
  setCameraError(null)
  try {
   const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: 'environment' }
   })
   streamRef.current = stream
   if (videoRef.current) {
    videoRef.current.srcObject = stream
    await videoRef.current.play()
   }
   setScanning(true)

   // Check if BarcodeDetector API is available
   if ('BarcodeDetector' in window) {
    setUseBarcodeDetector(true)
    const detector = new window.BarcodeDetector({ formats: ['qr_code'] })
    scanIntervalRef.current = setInterval(async () => {
     if (videoRef.current && videoRef.current.readyState === videoRef.current.HAVE_ENOUGH_DATA) {
      try {
       const barcodes = await detector.detect(videoRef.current)
       if (barcodes.length > 0) {
        const code = barcodes[0].rawValue
        if (code) {
         // Pause scanning while processing
         clearInterval(scanIntervalRef.current)
         await processCheckIn(code)
         // Resume scanning after reset timer
         setTimeout(() => {
          if (streamRef.current) {
           scanIntervalRef.current = setInterval(async () => {
            if (videoRef.current && videoRef.current.readyState === videoRef.current.HAVE_ENOUGH_DATA) {
             try {
              const results = await detector.detect(videoRef.current)
              if (results.length > 0 && results[0].rawValue) {
               clearInterval(scanIntervalRef.current)
               await processCheckIn(results[0].rawValue)
              }
             } catch { /* ignore detection errors */ }
            }
           }, 500)
          }
         }, 3500)
        }
       }
      } catch { /* ignore detection errors */ }
     }
    }, 500)
   } else {
    setUseBarcodeDetector(false)
   }
  } catch (err) {
   if (err.name === 'NotAllowedError') {
    setCameraError('Camera permission denied. Please allow camera access in your browser settings, or use the manual input below.')
   } else if (err.name === 'NotFoundError') {
    setCameraError('No camera found on this device. Use the manual input below to enter QR codes.')
   } else {
    setCameraError(`Could not access camera: ${err.message}. Use the manual input below.`)
   }
  }
 }, [processCheckIn])

 const stopCamera = useCallback(() => {
  if (scanIntervalRef.current) {
   clearInterval(scanIntervalRef.current)
   scanIntervalRef.current = null
  }
  if (streamRef.current) {
   streamRef.current.getTracks().forEach(track => track.stop())
   streamRef.current = null
  }
  if (videoRef.current) {
   videoRef.current.srcObject = null
  }
  setScanning(false)
 }, [])

 useEffect(() => {
  return () => {
   stopCamera()
   if (resetTimerRef.current) clearTimeout(resetTimerRef.current)
  }
 }, [stopCamera])

 const handleManualSubmit = async (e) => {
  e.preventDefault()
  if (!manualCode.trim() || manualSubmitting) return
  setManualSubmitting(true)
  await processCheckIn(manualCode.trim())
  setManualCode('')
  setManualSubmitting(false)
 }

 return (
  <div className="max-w-lg mx-auto px-4 py-6">
   <h1 className="text-2xl font-bold text-neutral-900 mb-2">Ticket Scanner</h1>
   <p className="text-neutral-600 mb-6">Scan attendee QR codes to check them in.</p>

   {/* Session counter */}
   <div className="mb-4 flex items-center justify-between">
    <span className="text-sm text-neutral-500">
     {sessionCount === 0 ? 'No tickets scanned yet' : `${sessionCount} ticket${sessionCount === 1 ? '' : 's'} checked in this session`}
    </span>
    {sessionCount > 0 && (
     <button
      onClick={() => setSessionCount(0)}
      className="text-xs text-brand-500 hover:text-brand-700"
     >
      Reset count
     </button>
    )}
   </div>

   {/* Scan result feedback */}
   {scanResult && (
    <div className={`mb-4 rounded-xl p-4 ${
     scanResult.type === 'success' ? 'bg-green-50 border border-green-200' :
     scanResult.type === 'warning' ? 'bg-yellow-50 border border-yellow-200' :
     'bg-red-50 border border-red-200'
    }`}>
     <div className="flex items-start">
      <div className="flex-shrink-0">
       {scanResult.type === 'success' && (
        <svg className="h-6 w-6 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
         <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
       )}
       {scanResult.type === 'warning' && (
        <svg className="h-6 w-6 text-yellow-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
         <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
        </svg>
       )}
       {scanResult.type === 'error' && (
        <svg className="h-6 w-6 text-red-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
         <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
       )}
      </div>
      <div className="ml-3 flex-1">
       <h3 className={`text-sm font-semibold ${
        scanResult.type === 'success' ? 'text-green-800' :
        scanResult.type === 'warning' ? 'text-yellow-800' :
        'text-red-800'
       }`}>
        {scanResult.message}
       </h3>
       {scanResult.detail && (
        <p className={`mt-1 text-sm ${
         scanResult.type === 'success' ? 'text-green-700' :
         scanResult.type === 'warning' ? 'text-yellow-700' :
         'text-red-700'
        }`}>
         {scanResult.detail}
        </p>
       )}
       {scanResult.ticket && (
        <div className={`mt-2 text-sm ${
         scanResult.type === 'success' ? 'text-green-700' :
         scanResult.type === 'warning' ? 'text-yellow-700' :
         'text-red-700'
        }`}>
         {scanResult.ticket.attendee_name && (
          <p><span className="font-medium">Attendee:</span> {scanResult.ticket.attendee_name}</p>
         )}
         {scanResult.ticket.ticket_type && (
          <p><span className="font-medium">Ticket:</span> {scanResult.ticket.ticket_type.name}</p>
         )}
         {scanResult.ticket.event && (
          <p><span className="font-medium">Event:</span> {scanResult.ticket.event.title}</p>
         )}
        </div>
       )}
      </div>
     </div>
    </div>
   )}

   {/* Camera section */}
   <div className="mb-6">
    <div className="bg-neutral-900 rounded-xl overflow-hidden relative" style={{ aspectRatio: '4/3' }}>
     {scanning ? (
      <>
       <video
        ref={videoRef}
        className="w-full h-full object-cover"
        playsInline
        muted
       />
       {/* Scanning overlay */}
       <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
        <div className="w-48 h-48 border-2 border-white/70 rounded-xl">
         <div className="absolute top-0 left-0 w-6 h-6 border-t-4 border-l-4 border-brand-400 rounded-tl-lg" />
         <div className="absolute top-0 right-0 w-6 h-6 border-t-4 border-r-4 border-brand-400 rounded-tr-lg" />
         <div className="absolute bottom-0 left-0 w-6 h-6 border-b-4 border-l-4 border-brand-400 rounded-bl-lg" />
         <div className="absolute bottom-0 right-0 w-6 h-6 border-b-4 border-r-4 border-brand-400 rounded-br-lg" />
        </div>
       </div>
       {!useBarcodeDetector && (
        <div className="absolute bottom-2 left-2 right-2 bg-yellow-900/80 text-yellow-200 text-xs px-2 py-1 rounded">
         Camera active but QR detection not supported in this browser. Use manual input below.
        </div>
       )}
      </>
     ) : (
      <div className="w-full h-full flex flex-col items-center justify-center text-neutral-400 p-4">
       <svg className="h-16 w-16 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
       </svg>
       <p className="text-sm text-center">Camera preview will appear here</p>
      </div>
     )}
    </div>

    {cameraError && (
     <div className="mt-2 p-3 bg-red-50 border border-red-200 rounded-xl">
      <p className="text-sm text-red-700">{cameraError}</p>
     </div>
    )}

    <div className="mt-3 flex gap-2">
     {!scanning ? (
      <button
       onClick={startCamera}
       className="flex-1 bg-brand-500 hover:bg-brand-600 text-white font-medium py-3 px-4 rounded-xl transition-colors flex items-center justify-center gap-2"
      >
       <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
       </svg>
       Start Camera
      </button>
     ) : (
      <button
       onClick={stopCamera}
       className="flex-1 bg-neutral-600 hover:bg-neutral-700 text-white font-medium py-3 px-4 rounded-xl transition-colors"
      >
       Stop Camera
      </button>
     )}
    </div>
   </div>

   {/* Manual input fallback */}
   <div className="border-t border-neutral-200 pt-6">
    <h2 className="text-lg font-semibold text-neutral-900 mb-2">Manual Entry</h2>
    <p className="text-sm text-neutral-500 mb-3">Enter or paste a ticket QR code value directly.</p>
    <form onSubmit={handleManualSubmit} className="flex flex-col sm:flex-row gap-2">
     <input
      type="text"
      value={manualCode}
      onChange={(e) => setManualCode(e.target.value)}
      placeholder="Enter QR code (UUID)"
      className="flex-1 border border-neutral-300 rounded-xl px-3 py-3 min-h-[44px] text-sm focus:ring-2 focus: focus:border-brand-500 outline-none"
      disabled={manualSubmitting}
     />
     <button
      type="submit"
      disabled={!manualCode.trim() || manualSubmitting}
      className="bg-orange-500 hover:bg-orange-600 disabled:bg-neutral-300 disabled:cursor-not-allowed text-white font-medium px-4 py-3 min-h-[44px] rounded-xl transition-colors whitespace-nowrap"
     >
      {manualSubmitting ? 'Checking...' : 'Check In'}
     </button>
    </form>
   </div>

   {/* Hidden canvas for frame capture (if needed for future image processing) */}
   <canvas ref={canvasRef} className="hidden" />
  </div>
 )
}
