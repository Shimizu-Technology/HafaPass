class IndexSalesExportStorageKey < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    # The orphan sweep resolves each S3 key against a durable request before
    # deletion. This index is added after the original migration shipped.
    add_index :organizer_sales_export_requests, :storage_key,
      name: "index_sales_exports_on_storage_key", algorithm: :concurrently
  end
end
