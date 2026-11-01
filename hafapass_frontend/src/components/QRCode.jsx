import { useTranslation } from 'react-i18next'
import { QRCodeSVG } from 'qrcode.react'

export default function QRCode({ value, size = 256, bgColor = '#ffffff', fgColor = '#000000', className }) {
  const { t } = useTranslation()
  return (
    <QRCodeSVG
      value={value}
      size={size}
      className={className}
      bgColor={bgColor}
      fgColor={fgColor}
      level="M"
      marginSize={2}
      title={t('buyer.qr.entryCode')}
      role="img"
      aria-label={t('buyer.qr.entryCode')}
    />
  )
}
