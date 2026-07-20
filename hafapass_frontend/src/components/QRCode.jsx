import { QRCodeSVG } from 'qrcode.react'

export default function QRCode({ value, size = 256, bgColor = '#ffffff', fgColor = '#000000' }) {
  return (
    <QRCodeSVG
      value={value}
      size={size}
      bgColor={bgColor}
      fgColor={fgColor}
      level="M"
      marginSize={2}
      title="Ticket entry QR code"
      role="img"
      aria-label={`QR code for ${value}`}
    />
  )
}
